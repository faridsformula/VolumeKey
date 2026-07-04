import Cocoa
import Network
import Carbon.HIToolbox
import Darwin

// MARK: - Raw HTTP via POSIX sockets (bypasses macOS Local Network TCC restrictions)

struct RawHTTPResponse {
    let status: Int
    let body: String
}

enum RawHTTP {
    static func request(host: String, port: UInt16, method: String, path: String,
                        headers: [String: String] = [:], body: String? = nil,
                        timeoutSec: Int = 5) -> RawHTTPResponse? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { Darwin.close(sock) }

        // Make socket non-blocking for connect with timeout
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult < 0 {
            if errno != EINPROGRESS { return nil }
            // Wait for connect to complete via poll (simpler than select in Swift)
            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let pollResult = poll(&pfd, 1, Int32(timeoutSec * 1000))
            if pollResult <= 0 { return nil }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &len)
            if soError != 0 { return nil }
        }
        // Restore blocking mode for send/recv with timeouts
        _ = fcntl(sock, F_SETFL, flags)
        var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Build request
        var req = "\(method) \(path) HTTP/1.1\r\n"
        req += "Host: \(host):\(port)\r\n"
        for (k, v) in headers { req += "\(k): \(v)\r\n" }
        if let body = body {
            req += "Content-Length: \(body.utf8.count)\r\n"
        }
        req += "Connection: close\r\n\r\n"
        if let body = body { req += body }

        let reqBytes = Array(req.utf8)
        var sent = 0
        while sent < reqBytes.count {
            let n = reqBytes.withUnsafeBufferPointer { buf -> Int in
                Darwin.send(sock, buf.baseAddress!.advanced(by: sent), reqBytes.count - sent, 0)
            }
            if n <= 0 { return nil }
            sent += n
        }

        // Read response
        var responseData = Data()
        let bufSize = 8192
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while true {
            let n = Darwin.recv(sock, buf, bufSize, 0)
            if n <= 0 { break }
            responseData.append(buf, count: n)
            if responseData.count > 5_000_000 { break } // sanity
        }
        guard !responseData.isEmpty else { return nil }
        // Parse: find header/body split
        let needle = Data([0x0d, 0x0a, 0x0d, 0x0a])
        guard let splitRange = responseData.range(of: needle) else { return nil }
        let headerData = responseData.subdata(in: 0..<splitRange.lowerBound)
        let bodyData = responseData.subdata(in: splitRange.upperBound..<responseData.count)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { return nil }

        // Handle chunked transfer encoding
        let isChunked = headerStr.lowercased().contains("transfer-encoding: chunked")
        let bodyText: String
        if isChunked {
            bodyText = decodeChunked(bodyData) ?? ""
        } else {
            bodyText = String(data: bodyData, encoding: .utf8) ?? ""
        }
        return RawHTTPResponse(status: status, body: bodyText)
    }

    private static func decodeChunked(_ data: Data) -> String? {
        var result = Data()
        var i = 0
        let bytes = [UInt8](data)
        while i < bytes.count {
            // Read chunk size line
            var lineEnd = i
            while lineEnd + 1 < bytes.count, !(bytes[lineEnd] == 0x0d && bytes[lineEnd + 1] == 0x0a) {
                lineEnd += 1
            }
            let sizeStr = String(bytes: Array(bytes[i..<lineEnd]), encoding: .ascii) ?? ""
            guard let chunkSize = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            i = lineEnd + 2
            if chunkSize == 0 { break }
            guard i + chunkSize <= bytes.count else { return nil }
            result.append(Array(bytes[i..<i + chunkSize]), count: chunkSize)
            i += chunkSize + 2 // skip trailing CRLF
        }
        return String(data: result, encoding: .utf8)
    }
}

// MARK: - Sonos device

struct SonosMember: Equatable {
    let name: String  // room name of this individual speaker
    let ip: String
    let uuid: String
    var satellites: [SonosMember] = []  // bonded HT satellites (surrounds, sub) — empty for non-HT zones
}

struct SonosDevice: Equatable {
    let name: String       // display name (single room, or "A + B + C" if grouped)
    let ip: String         // coordinator IP — used for group volume
    let uuid: String       // coordinator UUID — stable id for this zone group
    let members: [SonosMember]  // visible members (excludes bonded satellites)
}

// MARK: - Discovery: subnet scan → topology fetch → one entry per zone

final class SonosDiscovery {
    var onFound: ((SonosDevice) -> Void)?
    var onComplete: (() -> Void)?
    private let queue = DispatchQueue(label: "sonos.discovery", attributes: .concurrent)

    func start() {
        queue.async { self.discover() }
    }

    private func localSubnets() -> [String] {
        var prefixes: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return prefixes }
        defer { freeifaddrs(ifaddrPtr) }
        var ptr = ifaddrPtr
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            if (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
               let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var addr = sockaddr_in()
                memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                let parts = ip.split(separator: ".")
                if parts.count == 4, !ip.hasPrefix("169.254") {
                    prefixes.append("\(parts[0]).\(parts[1]).\(parts[2])")
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return Array(Set(prefixes))
    }

    private func discover() {
        let prefixes = localSubnets()
        NSLog("VolumeKey: scanning subnets: \(prefixes)")

        var sonosIPs = [String]()
        let lock = NSLock()
        let group = DispatchGroup()
        let scanQueue = DispatchQueue(label: "sonos.scan", attributes: .concurrent)
        for prefix in prefixes {
            for i in 1...254 {
                let ip = "\(prefix).\(i)"
                group.enter()
                scanQueue.async {
                    defer { group.leave() }
                    if let resp = RawHTTP.request(host: ip, port: 1400, method: "GET",
                                                  path: "/xml/device_description.xml",
                                                  timeoutSec: 1),
                       resp.status == 200, !resp.body.isEmpty {
                        lock.lock(); sonosIPs.append(ip); lock.unlock()
                    }
                }
            }
        }
        group.wait()
        NSLog("VolumeKey: found \(sonosIPs.count) Sonos device(s): \(sonosIPs)")

        guard !sonosIPs.isEmpty else {
            DispatchQueue.main.async { self.onComplete?() }
            return
        }
        fetchTopology(from: sonosIPs)
    }

    private func fetchTopology(from ips: [String], attempt: Int = 0) {
        DispatchQueue.global(qos: .utility).async {
            for ip in ips {
                let body = """
                <?xml version="1.0" encoding="utf-8"?>
                <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
                <s:Body><u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"></u:GetZoneGroupState></s:Body></s:Envelope>
                """
                let resp = RawHTTP.request(
                    host: ip, port: 1400, method: "POST",
                    path: "/ZoneGroupTopology/Control",
                    headers: [
                        "Content-Type": "text/xml; charset=\"utf-8\"",
                        "SOAPACTION": "\"urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState\""
                    ],
                    body: body, timeoutSec: 5)
                if let resp = resp, resp.status == 200, resp.body.contains("ZoneGroup") {
                    NSLog("VolumeKey: topology body length \(resp.body.count) from \(ip)")
                    let unescaped = resp.body
                        .replacingOccurrences(of: "&lt;", with: "<")
                        .replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "&quot;", with: "\"")
                        .replacingOccurrences(of: "&amp;", with: "&")
                    self.parseZones(unescaped)
                    DispatchQueue.main.async { self.onComplete?() }
                    return
                }
                NSLog("VolumeKey: topology fetch from \(ip) failed — trying next")
            }
            NSLog("VolumeKey: topology fetch failed — exhausted all IPs")
            DispatchQueue.main.async { self.onComplete?() }
        }
    }

    private func parseZones(_ xml: String) {
        // For each <ZoneGroup Coordinator="..." ...> ... </ZoneGroup>,
        // collect all top-level <ZoneGroupMember .../> entries (excluding nested <Satellite/> which are bonded HT slaves).
        var idx = xml.startIndex
        while let gStart = xml.range(of: "<ZoneGroup ", range: idx..<xml.endIndex),
              let gEnd = xml.range(of: "</ZoneGroup>", range: gStart.upperBound..<xml.endIndex) {
            let groupHeaderEnd = xml.range(of: ">", range: gStart.upperBound..<gEnd.lowerBound)?.lowerBound ?? gEnd.lowerBound
            let groupHeader = String(xml[gStart.upperBound..<groupHeaderEnd])
            let groupBlock = String(xml[gStart.upperBound..<gEnd.lowerBound])
            idx = gEnd.upperBound

            let coordinatorUUID = attr(groupHeader, "Coordinator") ?? ""

            // Extract each ZoneGroupMember and its inner Satellite elements.
            var members: [SonosMember] = []
            var coordinatorMember: SonosMember?
            var searchIdx = groupBlock.startIndex
            while let mStart = groupBlock.range(of: "<ZoneGroupMember ", range: searchIdx..<groupBlock.endIndex) {
                guard let tagEnd = groupBlock.range(of: ">", range: mStart.upperBound..<groupBlock.endIndex) else { break }
                let attrs = String(groupBlock[mStart.upperBound..<tagEnd.lowerBound])

                // Determine the extent of this member (until matching </ZoneGroupMember> or end of self-closing tag).
                let memberSelfClosed = attrs.hasSuffix("/")
                let memberBodyEnd: String.Index
                if memberSelfClosed {
                    memberBodyEnd = tagEnd.upperBound
                } else if let close = groupBlock.range(of: "</ZoneGroupMember>", range: tagEnd.upperBound..<groupBlock.endIndex) {
                    memberBodyEnd = close.upperBound
                } else {
                    memberBodyEnd = tagEnd.upperBound
                }
                let memberBody = String(groupBlock[tagEnd.upperBound..<memberBodyEnd])
                searchIdx = memberBodyEnd

                if attr(attrs, "Invisible") == "1" { continue }
                let zoneName = attr(attrs, "ZoneName") ?? "Unknown"
                let location = attr(attrs, "Location") ?? ""
                let uuid = attr(attrs, "UUID") ?? location
                guard let url = URL(string: location), let host = url.host else { continue }

                // Parse Satellite tags inside this ZoneGroupMember body
                var sats: [SonosMember] = []
                var satIdx = memberBody.startIndex
                while let sStart = memberBody.range(of: "<Satellite ", range: satIdx..<memberBody.endIndex) {
                    guard let sEnd = memberBody.range(of: ">", range: sStart.upperBound..<memberBody.endIndex) else { break }
                    let satAttrs = String(memberBody[sStart.upperBound..<sEnd.lowerBound])
                    satIdx = sEnd.upperBound
                    let satName = attr(satAttrs, "ZoneName") ?? "Speaker"
                    let satLoc = attr(satAttrs, "Location") ?? ""
                    let satUUID = attr(satAttrs, "UUID") ?? satLoc
                    let chanMap = attr(satAttrs, "HTSatChanMapSet") ?? ""
                    guard let satURL = URL(string: satLoc), let satHost = satURL.host else { continue }
                    let label = labelForSatellite(uuid: satUUID, fallback: satName, channelMap: chanMap)
                    sats.append(SonosMember(name: label, ip: satHost, uuid: satUUID))
                }

                let m = SonosMember(name: zoneName, ip: host, uuid: uuid, satellites: sats)
                members.append(m)
                if uuid == coordinatorUUID { coordinatorMember = m }
            }
            guard let coord = coordinatorMember ?? members.first else { continue }
            let displayName: String
            if members.count <= 1 {
                displayName = coord.name
            } else {
                let others = members.filter { $0.uuid != coord.uuid }.map(\.name)
                displayName = ([coord.name] + others).joined(separator: " + ")
            }
            let dev = SonosDevice(name: displayName, ip: coord.ip, uuid: coord.uuid, members: members)
            NSLog("VolumeKey: zone found: \(displayName) (members: \(members.count))")
            DispatchQueue.main.async { self.onFound?(dev) }
        }
    }

    private func attr(_ s: String, _ name: String) -> String? {
        guard let r = s.range(of: "\(name)=\"") else { return nil }
        let after = s[r.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<end])
    }

    // Translate a satellite's HTSatChanMapSet into a friendly channel name.
    // Format example: "RINCON_AAA:LF,RF;RINCON_BBB:SW;RINCON_CCC:LR,LTR;RINCON_DDD:RR,RTR"
    private func labelForSatellite(uuid: String, fallback: String, channelMap: String) -> String {
        for entry in channelMap.split(separator: ";") {
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == uuid else { continue }
            let channels = parts[1]
            if channels.contains("SW") { return "Sub" }
            if channels.contains("LR") || channels.contains("LTR") { return "Left surround" }
            if channels.contains("RR") || channels.contains("RTR") { return "Right surround" }
        }
        return fallback
    }
}

// MARK: - Sonos control

final class SonosController {
    private var volumeCache: [String: Int] = [:]
    private let cacheLock = NSLock()

    func cachedVolume(for uuid: String) -> Int? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return volumeCache[uuid]
    }
    private func writeCache(_ uuid: String, _ v: Int) {
        cacheLock.lock(); volumeCache[uuid] = v; cacheLock.unlock()
    }

    func setRelativeVolume(device: SonosDevice, delta: Int, completion: @escaping (Int?) -> Void) {
        soap(device: device, service: "GroupRenderingControl", action: "SetRelativeGroupVolume",
             args: ["InstanceID": "0", "Adjustment": "\(delta)"]) { result in
            if let xml = result, let r = xml.range(of: "<NewVolume>"),
               let e = xml.range(of: "</NewVolume>") {
                completion(Int(xml[r.upperBound..<e.lowerBound]))
            } else { completion(nil) }
        }
    }

    func getVolume(device: SonosDevice, completion: @escaping (Int?) -> Void) {
        soap(device: device, service: "GroupRenderingControl", action: "GetGroupVolume",
             args: ["InstanceID": "0"]) { result in
            if let xml = result, let r = xml.range(of: "<CurrentVolume>"),
               let e = xml.range(of: "</CurrentVolume>") {
                completion(Int(xml[r.upperBound..<e.lowerBound]))
            } else { completion(nil) }
        }
    }

    func setMute(device: SonosDevice, muted: Bool, completion: @escaping () -> Void) {
        soap(device: device, service: "GroupRenderingControl", action: "SetGroupMute",
             args: ["InstanceID": "0", "DesiredMute": muted ? "1" : "0"]) { _ in
            completion()
        }
    }

    func getMute(device: SonosDevice, completion: @escaping (Bool) -> Void) {
        soap(device: device, service: "GroupRenderingControl", action: "GetGroupMute",
             args: ["InstanceID": "0"]) { result in
            if let xml = result, let r = xml.range(of: "<CurrentMute>"),
               let e = xml.range(of: "</CurrentMute>") {
                completion(xml[r.upperBound..<e.lowerBound] == "1")
            } else { completion(false) }
        }
    }

    // Per-member volume (controls one individual speaker, preserving its group offset).
    func getMemberVolume(member: SonosMember, completion: @escaping (Int?) -> Void) {
        memberSoap(ip: member.ip, action: "GetVolume",
                   args: ["InstanceID": "0", "Channel": "Master"]) { [weak self] xml in
            if let xml = xml, let r = xml.range(of: "<CurrentVolume>"),
               let e = xml.range(of: "</CurrentVolume>"),
               let v = Int(xml[r.upperBound..<e.lowerBound]) {
                self?.writeCache(member.uuid, v)
                completion(v)
            } else { completion(nil) }
        }
    }

    // Make `joiningCoordinatorIP` (and its bonded members) join the group whose coordinator is `targetUUID`.
    func joinGroup(joiningCoordinatorIP: String, targetCoordinatorUUID: String, completion: @escaping () -> Void) {
        avTransport(ip: joiningCoordinatorIP, action: "SetAVTransportURI",
                    args: ["InstanceID": "0",
                           "CurrentURI": "x-rincon:\(targetCoordinatorUUID)",
                           "CurrentURIMetaData": ""]) { _ in completion() }
    }

    // Make `leavingCoordinatorIP` leave its current group and become standalone.
    func leaveGroup(leavingCoordinatorIP: String, completion: @escaping () -> Void) {
        avTransport(ip: leavingCoordinatorIP, action: "BecomeCoordinatorOfStandaloneGroup",
                    args: ["InstanceID": "0"]) { _ in completion() }
    }

    private func avTransport(ip: String, action: String, args: [String: String],
                             completion: @escaping (String?) -> Void) {
        rawSoap(ip: ip, path: "/MediaRenderer/AVTransport/Control",
                service: "AVTransport", action: action, args: args, completion: completion)
    }

    func setMemberVolume(member: SonosMember, volume: Int, completion: @escaping () -> Void) {
        let v = max(0, min(100, volume))
        writeCache(member.uuid, v)  // optimistic update so subsequent reads see the new value
        memberSoap(ip: member.ip, action: "SetVolume",
                   args: ["InstanceID": "0", "Channel": "Master", "DesiredVolume": "\(v)"]) { _ in
            completion()
        }
    }

    private func memberSoap(ip: String, action: String, args: [String: String],
                            completion: @escaping (String?) -> Void) {
        rawSoap(ip: ip, path: "/MediaRenderer/RenderingControl/Control",
                service: "RenderingControl", action: action, args: args, completion: completion)
    }

    private func soap(device: SonosDevice, service: String, action: String, args: [String: String],
                      completion: @escaping (String?) -> Void) {
        rawSoap(ip: device.ip, path: "/MediaRenderer/\(service)/Control",
                service: service, action: action, args: args, completion: completion)
    }

    private func rawSoap(ip: String, path: String, service: String, action: String,
                         args: [String: String], completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let argsXML = args.map { "<\($0.key)>\($0.value)</\($0.key)>" }.joined()
            let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:\(service):1">\(argsXML)</u:\(action)></s:Body>
            </s:Envelope>
            """
            let resp = RawHTTP.request(
                host: ip, port: 1400, method: "POST", path: path,
                headers: [
                    "Content-Type": "text/xml; charset=\"utf-8\"",
                    "SOAPACTION": "\"urn:schemas-upnp-org:service:\(service):1#\(action)\""
                ],
                body: body, timeoutSec: 5)
            completion(resp?.body)
        }
    }
}

// MARK: - Key hijack via CGEventTap on system-defined events

final class KeyHijacker {
    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onMute: (() -> Void)?
    var onMicMute: (() -> Void)?  // ⌥ + mute key
    var enabled = true
    /// Consulted per volume-key press; returning false passes the key through
    /// to macOS (e.g. headphones with native volume are the default output).
    var shouldHijack: (() -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSrc: CFRunLoopSource?

    func start() {
        let mask = CGEventMask(1 << 14) // NSSystemDefined / kCGEventSystemDefined
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyHijacker>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: ref) else {
            NSLog("VolumeKey: tap creation failed (need Accessibility permission) — retrying in 3s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
            return
        }
        NSLog("VolumeKey: key tap active")
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.runLoopSrc = src
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard enabled else { return Unmanaged.passUnretained(event) }
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        guard keyCode == 0 || keyCode == 1 || keyCode == 7 else {
            return Unmanaged.passUnretained(event)
        }
        // ⌥ + mute toggles the MICROPHONE — always ours, regardless of output routing.
        if keyCode == 7, nsEvent.modifierFlags.contains(.option) {
            if keyDown { onMicMute?() }
            return nil
        }
        // Both down AND up must pass through when macOS owns the keys,
        // otherwise the system sees half a key press.
        if shouldHijack?() == false { return Unmanaged.passUnretained(event) }
        if !keyDown { return nil } // swallow up event too if we handled the key
        NSLog("VolumeKey: hijack key code \(keyCode) (data1=\(data1))")
        switch keyCode {
        case 0: // NX_KEYTYPE_SOUND_UP
            onVolumeUp?(); return nil
        case 1: // NX_KEYTYPE_SOUND_DOWN
            onVolumeDown?(); return nil
        case 7: // NX_KEYTYPE_MUTE
            onMute?(); return nil
        default:
            return nil
        }
    }
}

// MARK: - Volume HUD

final class VolumeHUD {
    private var window: NSWindow?
    private var bar: NSView?
    private var label: NSTextField?
    private var hideTimer: Timer?

    func show(volume: Int, muted: Bool = false, label deviceLabel: String = "Sonos") {
        if window == nil { build() }
        guard let w = window, let v = w.contentView, let bar = bar, let label = label else { return }
        let pct = max(0, min(100, volume))
        let width = (v.bounds.width - 40) * CGFloat(pct) / 100.0
        bar.isHidden = false
        bar.frame = NSRect(x: 20, y: 20, width: width, height: 8)
        bar.layer?.backgroundColor = muted ? NSColor.systemRed.cgColor : NSColor.white.cgColor
        label.frame = NSRect(x: 20, y: 40, width: 220, height: 24)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.maximumNumberOfLines = 1
        label.stringValue = muted ? "\(deviceLabel)  Muted" : "\(deviceLabel)  \(volume)"
        w.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.window?.orderOut(nil)
        }
    }

    // Text-only variant for status messages (pairing prompts, unreachable TV).
    func showMessage(_ text: String) {
        if window == nil { build() }
        guard let w = window, let bar = bar, let label = label else { return }
        bar.isHidden = true
        label.frame = NSRect(x: 20, y: 12, width: 220, height: 56)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.stringValue = text
        w.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.window?.orderOut(nil)
        }
    }

    private func build() {
        let size = NSSize(width: 260, height: 80)
        let screen = NSScreen.main!.frame
        let rect = NSRect(x: (screen.width - size.width) / 2,
                          y: 100,
                          width: size.width, height: size.height)
        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        content.layer?.cornerRadius = 14

        let track = NSView(frame: NSRect(x: 20, y: 20, width: size.width - 40, height: 8))
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        track.layer?.cornerRadius = 4
        content.addSubview(track)

        let barView = NSView(frame: NSRect(x: 20, y: 20, width: 0, height: 8))
        barView.wantsLayer = true
        barView.layer?.backgroundColor = NSColor.white.cgColor
        barView.layer?.cornerRadius = 4
        content.addSubview(barView)
        self.bar = barView

        let labelView = NSTextField(labelWithString: "")
        labelView.frame = NSRect(x: 20, y: 40, width: size.width - 40, height: 24)
        labelView.textColor = .white
        labelView.font = .systemFont(ofSize: 14, weight: .medium)
        labelView.backgroundColor = .clear
        labelView.isBordered = false
        content.addSubview(labelView)
        self.label = labelView

        w.contentView = content
        window = w
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Always refresh topology when the user opens the menu so manual reopen sees fresh state.
        silentRefresh()
        for r in targetRows { r.refresh() }
    }

    var statusItem: NSStatusItem!
    let discovery = SonosDiscovery()
    let controller = SonosController()
    let hijacker = KeyHijacker()
    let hud = VolumeHUD()
    let audioMonitor = AudioOutputMonitor()
    let micMute = MicMuteController()

    // Auto-switch: when the default output has native volume (AirPods, BT
    // headphones, speakers), volume keys stay with macOS; when it doesn't
    // (HDMI → TV), keys go to the selected TV. Only applies to TV targets.
    var followAudioOutput: Bool {
        get { UserDefaults.standard.object(forKey: "followAudioOutput") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "followAudioOutput") }
    }

    var devices: [SonosDevice] = []
    var netTargets: [VolumeTarget] = []          // LG webOS, DLNA, Roku, DDC displays
    var lgConnections: [String: LGTVConnection] = [:]
    var selectedUUID: String? {
        get { UserDefaults.standard.string(forKey: "selectedUUID") }
        set { UserDefaults.standard.set(newValue, forKey: "selectedUUID") }
    }
    var stepSize: Int {
        get { max(1, UserDefaults.standard.integer(forKey: "stepSize")) }
        set { UserDefaults.standard.set(newValue, forKey: "stepSize") }
    }
    var paused = false
    private var memberRows: [MemberVolumeRow] = []
    private var groupRows: [GroupCheckboxRow] = []
    private var targetRows: [TargetVolumeRow] = []
    private var lgRetryPending = false
    private var refreshWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        let logPath = "/tmp/volumekey.log"
        freopen(logPath, "a", stderr)
        NSLog("=== VolumeKey launched ===")
        migrateFromSonosKey()
        if stepSize == 0 { stepSize = 3 }
        ensureAccessibility()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "VolumeKey") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "S"
            }
        }
        rebuildMenu()
        // When user opens the menu, also re-trigger network probe (in case Local Network just got granted)
        statusItem.menu?.delegate = self

        discovery.onFound = { [weak self] dev in
            guard let self = self else { return }
            if !self.devices.contains(where: { $0.uuid == dev.uuid }) {
                self.devices.append(dev)
                if self.selectedUUID == nil { self.selectedUUID = dev.uuid }
                self.rebuildMenu()
            }
        }
        discovery.start()
        startLGDiscovery()
        // DLNA after LG so webOS TVs are known and excluded from the renderer list.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            self?.startDLNADiscovery()
        }
        startRokuDiscovery()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let displays = DDCDiscovery.scan()   // blocking I2C probes — off-main
            DispatchQueue.main.async { displays.forEach { self?.addTarget($0) } }
        }

        hijacker.onVolumeUp = { [weak self] in self?.bump(+1) }
        hijacker.onVolumeDown = { [weak self] in self?.bump(-1) }
        hijacker.onMute = { [weak self] in self?.toggleMute() }
        hijacker.onMicMute = { [weak self] in self?.toggleMicMute() }
        hijacker.shouldHijack = { [weak self] in
            guard let self = self else { return true }
            // Sonos targets always hijack (Sonos is never the Mac's own output).
            // TV/display targets defer to headphones/speakers when they own the output.
            if self.selectedNetTarget != nil, self.followAudioOutput, self.audioMonitor.hasNativeVolume {
                return false
            }
            return true
        }
        hijacker.start()

        audioMonitor.onChange = { [weak self] in
            guard let self = self, let target = self.selectedNetTarget, self.followAudioOutput else { return }
            let dest = self.audioMonitor.hasNativeVolume ? self.audioMonitor.outputName : target.name
            self.hud.showMessage("Volume keys → \(dest)")
        }
        audioMonitor.start()
        micMute.start()
    }

    func toggleMicMute() {
        if let (muted, name) = micMute.toggle() {
            hud.showMessage(muted ? "🎙 Mic muted — \(name)" : "🎙 Mic live — \(name)")
        } else {
            hud.showMessage("Mic mute unavailable for this input device")
        }
        rebuildMenu()
    }

    // One-time import from the app's previous identity (SonosKey) — keeps TV
    // pairings (client keys), selected target, and preferences across the rename.
    func migrateFromSonosKey() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromSonosKey"),
              let old = d.persistentDomain(forName: "com.faridsformula.sonoskey2") else { return }
        for (key, value) in old where d.object(forKey: key) == nil {
            d.set(value, forKey: key)
        }
        d.set(true, forKey: "migratedFromSonosKey")
        NSLog("VolumeKey: migrated \(old.count) settings from SonosKey")
    }

    func ensureAccessibility() {
        // Check trusted state silently — do NOT prompt on every launch.
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    var selectedDevice: SonosDevice? {
        guard let id = selectedUUID else { return devices.first }
        if let d = devices.first(where: { $0.uuid == id }) { return d }
        if netTargets.contains(where: { $0.uuid == id }) { return nil }  // a net target is selected
        return devices.first
    }

    var selectedNetTarget: VolumeTarget? {
        guard let id = selectedUUID else { return nil }
        return netTargets.first(where: { $0.uuid == id })
    }

    // MARK: Network / display targets (LG webOS, DLNA, Roku, DDC)

    func addTarget(_ t: VolumeTarget) {
        guard !netTargets.contains(where: { $0.uuid == t.uuid }) else { return }
        // One backend per box: skip if another backend already owns this IP.
        if !t.ip.isEmpty, netTargets.contains(where: { $0.ip == t.ip }) { return }
        netTargets.append(t)
        if selectedUUID == nil { selectedUUID = t.uuid }
        rebuildMenu()
    }

    func startLGDiscovery(retriesLeft: Int = 6) {
        let probe = LGTVDiscovery()
        probe.onComplete = { [weak self] in
            guard let self = self else { return }
            // Nothing found yet (e.g. Local Network permission granted after launch) — retry.
            if self.netTargets.isEmpty && retriesLeft > 0 && !self.lgRetryPending {
                self.lgRetryPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.lgRetryPending = false
                    self.startLGDiscovery(retriesLeft: retriesLeft - 1)
                }
            }
        }
        probe.onFound = { [weak self] dev in
            guard let self = self else { return }
            if let existing = self.lgConnections[dev.uuid] { existing.updateIP(dev.ip) }
            let conn = self.lgConnection(for: dev)
            self.addTarget(conn)
            // Eager-connect the selected TV so the first key press is instant.
            if dev.uuid == self.selectedUUID { conn.connect() }
        }
        probe.start()
    }

    func lgConnection(for dev: LGTVDevice) -> LGTVConnection {
        if let c = lgConnections[dev.uuid] { return c }
        let c = LGTVConnection(device: dev)
        c.onUserMessage = { [weak self] text in self?.hud.showMessage(text) }
        lgConnections[dev.uuid] = c
        return c
    }

    func startDLNADiscovery() {
        let probe = DLNADiscovery()
        // Skip boxes a native backend already covers: LG TVs and Sonos zones.
        var excluded = Set(netTargets.map(\.ip).filter { !$0.isEmpty })
        for zone in devices { for m in zone.members { excluded.insert(m.ip) } }
        probe.onFound = { [weak self] renderer in self?.addTarget(renderer) }
        probe.start(excludedIPs: excluded)
    }

    func startRokuDiscovery() {
        let probe = RokuDiscovery()
        probe.onFound = { [weak self] roku in self?.addTarget(roku) }
        probe.start()
    }

    func bump(_ dir: Int) {
        guard !paused else { NSSound.beep(); return }
        if let target = selectedNetTarget {
            target.bump(delta: dir * stepSize) { [weak self] vol, muted in
                if let v = vol {
                    self?.hud.show(volume: v, muted: muted, label: target.kindLabel)
                } else {
                    self?.hud.showMessage("\(target.name)  \(dir > 0 ? "▲" : "▼")")
                }
            }
            return
        }
        guard let dev = selectedDevice else { NSSound.beep(); return }
        let delta = dir * stepSize
        var displayVol: Int? = nil
        for m in dev.members {
            // Use cached value if known; otherwise fall back to querying then setting.
            if let cached = controller.cachedVolume(for: m.uuid) {
                let target = max(0, min(100, cached + delta))
                if displayVol == nil { displayVol = target }
                controller.setMemberVolume(member: m, volume: target) {}
                // Update visible slider immediately
                if let row = memberRows.first(where: { $0.member.uuid == m.uuid }) {
                    row.slider.doubleValue = Double(target)
                    row.value.stringValue = "\(target)"
                }
            } else {
                controller.getMemberVolume(member: m) { [weak self] current in
                    guard let self = self, let cur = current else { return }
                    let target = max(0, min(100, cur + delta))
                    self.controller.setMemberVolume(member: m, volume: target) {}
                    DispatchQueue.main.async {
                        if let row = self.memberRows.first(where: { $0.member.uuid == m.uuid }) {
                            row.slider.doubleValue = Double(target)
                            row.value.stringValue = "\(target)"
                        }
                    }
                }
            }
        }
        if let v = displayVol { hud.show(volume: v) }
    }

    func toggleMute() {
        guard !paused else { return }
        if let target = selectedNetTarget {
            target.toggleMute { [weak self] vol, muted in
                if let v = vol {
                    self?.hud.show(volume: v, muted: muted, label: target.kindLabel)
                } else {
                    self?.hud.showMessage("\(target.name)  mute")
                }
            }
            return
        }
        guard let dev = selectedDevice else { return }
        controller.getMute(device: dev) { [weak self] muted in
            self?.controller.setMute(device: dev, muted: !muted) {
                self?.controller.getVolume(device: dev) { vol in
                    DispatchQueue.main.async {
                        self?.hud.show(volume: vol ?? 0, muted: !muted)
                        self?.refreshAllRowsSoon()
                    }
                }
            }
        }
    }

    func refreshAllRowsSoon() {
        // Debounce: coalesce rapid key presses into one refresh ~250ms after the last bump.
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            for r in self.memberRows { r.refresh() }
            for r in self.groupRows { r.refresh() }
            for r in self.targetRows { r.refresh() }
        }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func rebuildMenu() {
        memberRows.removeAll()
        groupRows.removeAll()
        targetRows.removeAll()
        // Reuse the SAME NSMenu instance so modifications appear live in the currently-open menu.
        let menu = statusItem.menu ?? NSMenu()
        menu.removeAllItems()
        if devices.isEmpty && netTargets.isEmpty {
            menu.addItem(NSMenuItem(title: "Searching for Sonos & LG TVs…", action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Volume keys target:", action: nil, keyEquivalent: ""))
            let sortedDevices = devices.sorted(by: { $0.name < $1.name })
            for d in sortedDevices {
                let item = NSMenuItem(title: d.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = d.uuid
                if d.uuid == selectedDevice?.uuid { item.state = .on }

                let sub = NSMenu()
                // Per-member sliders. Coordinator has no checkbox; satellites get an "ungroup" checkbox.
                let totalSatellites = d.members.reduce(0) { $0 + $1.satellites.count }
                for m in d.members {
                    let row = NSMenuItem()
                    let isCoord = (m.uuid == d.uuid)
                    let canUngroup = !isCoord  // satellites only
                    let memberIP = m.ip
                    let view = MemberVolumeRow(
                        member: m, controller: controller,
                        isCoordinator: isCoord, canUngroup: canUngroup
                    ) { [weak self] in
                        guard let self = self else { return }
                        NSLog("VolumeKey: user unchecked member \(memberIP) — leaving group")
                        self.controller.leaveGroup(leavingCoordinatorIP: memberIP) {
                            NSLog("VolumeKey: leaveGroup SOAP returned for \(memberIP)")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.silentRefresh(retriesLeft: 4, expectChange: true) }
                        }
                    }
                    view.refresh()
                    row.view = view
                    sub.addItem(row)
                    memberRows.append(view)
                }

                // Detailed speakers submenu — includes bonded HT satellites (Sub, surrounds).
                if totalSatellites > 0 {
                    sub.addItem(.separator())
                    let detailItem = NSMenuItem(title: "Detailed speakers", action: nil, keyEquivalent: "")
                    let detailMenu = NSMenu()
                    for m in d.members {
                        // Header row for this visible member if it has satellites
                        if !m.satellites.isEmpty {
                            let header = NSMenuItem(title: m.name, action: nil, keyEquivalent: "")
                            detailMenu.addItem(header)
                        }
                        // The visible member itself (slider)
                        let mainRow = NSMenuItem()
                        let mainView = MemberVolumeRow(member: m, controller: controller)
                        mainView.refresh()
                        mainRow.view = mainView
                        detailMenu.addItem(mainRow)
                        memberRows.append(mainView)
                        // Each satellite as its own slider row
                        for sat in m.satellites {
                            let satRow = NSMenuItem()
                            let satView = MemberVolumeRow(member: sat, controller: controller)
                            satView.refresh()
                            satRow.view = satView
                            detailMenu.addItem(satRow)
                            memberRows.append(satView)
                        }
                    }
                    detailItem.submenu = detailMenu
                    sub.addItem(detailItem)
                }

                let others = sortedDevices.filter { $0.uuid != d.uuid }
                if !others.isEmpty {
                    sub.addItem(.separator())
                    let header = NSMenuItem(title: "Play also in:", action: nil, keyEquivalent: "")
                    sub.addItem(header)
                    let inGroup = Set(d.members.map(\.uuid))
                    let zoneCoordIP = d.ip
                    let zoneCoordUUID = d.uuid
                    for other in others {
                        let row = NSMenuItem()
                        let view = GroupCheckboxRow(
                            otherZone: other,
                            isMember: inGroup.contains(other.uuid),
                            controller: controller
                        ) { [weak self] checked in
                            guard let self = self else { return }
                            if checked {
                                NSLog("VolumeKey: joining \(other.ip) → \(zoneCoordUUID)")
                                self.controller.joinGroup(joiningCoordinatorIP: other.ip,
                                                          targetCoordinatorUUID: zoneCoordUUID) {
                                    NSLog("VolumeKey: joinGroup SOAP returned for \(other.ip)")
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.silentRefresh(retriesLeft: 4, expectChange: true) }
                                }
                            } else {
                                NSLog("VolumeKey: leaving group via GroupCheckboxRow uncheck of \(other.ip)")
                                self.controller.leaveGroup(leavingCoordinatorIP: other.ip) {
                                    NSLog("VolumeKey: leaveGroup SOAP returned for \(other.ip)")
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.silentRefresh(retriesLeft: 4, expectChange: true) }
                                }
                            }
                            _ = zoneCoordIP
                        }
                        row.view = view
                        sub.addItem(row)
                        groupRows.append(view)
                    }
                }

                if d.members.count > 1 {
                    sub.addItem(.separator())
                    let ungroupAll = NSMenuItem(title: "Ungroup all",
                                                action: #selector(ungroupAll(_:)), keyEquivalent: "")
                    ungroupAll.target = self
                    ungroupAll.representedObject = d.uuid
                    sub.addItem(ungroupAll)
                }

                item.submenu = sub
                menu.addItem(item)
            }

            // Network/display targets (LG webOS, DLNA renderers, Roku, DDC displays).
            for target in netTargets.sorted(by: { $0.name < $1.name }) {
                let item = NSMenuItem(title: target.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = target.uuid
                if target.uuid == selectedUUID { item.state = .on }
                let sub = NSMenu()
                if target.supportsAbsoluteVolume {
                    let row = NSMenuItem()
                    let view = TargetVolumeRow(target: target)
                    row.view = view
                    sub.addItem(row)
                    targetRows.append(view)
                } else {
                    sub.addItem(NSMenuItem(title: "Relative volume only (no readback)",
                                           action: nil, keyEquivalent: ""))
                }
                if target is LGTVConnection,
                   UserDefaults.standard.string(forKey: "lgtv.clientKey.\(target.uuid)") == nil {
                    sub.addItem(.separator())
                    let pair = NSMenuItem(title: "Pair with TV…", action: #selector(pairTV(_:)), keyEquivalent: "")
                    pair.target = self
                    pair.representedObject = target.uuid
                    sub.addItem(pair)
                }
                item.submenu = sub
                menu.addItem(item)
            }

            if !devices.isEmpty {
                menu.addItem(.separator())
                let mixer = NSMenuItem(title: "Open Mixer…", action: #selector(openMixer), keyEquivalent: "m")
                mixer.target = self
                menu.addItem(mixer)
            }
        }
        menu.addItem(.separator())

        let stepMenu = NSMenu()
        for s in [1, 2, 3, 5, 10] {
            let it = NSMenuItem(title: "\(s)", action: #selector(setStep(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s
            if s == stepSize { it.state = .on }
            stepMenu.addItem(it)
        }
        let stepParent = NSMenuItem(title: "Step size (\(stepSize))", action: nil, keyEquivalent: "")
        stepParent.submenu = stepMenu
        menu.addItem(stepParent)

        let micItem = NSMenuItem(title: "Mute microphone   ⌥ + mute key",
                                 action: #selector(micMuteClicked), keyEquivalent: "")
        micItem.target = self
        micItem.state = micMute.muted ? .on : .off
        if let name = micMute.inputName() { micItem.toolTip = "Default input: \(name)" }
        menu.addItem(micItem)

        let followItem = NSMenuItem(title: "Headphones take the keys when connected",
                                    action: #selector(toggleFollowAudio), keyEquivalent: "")
        followItem.target = self
        followItem.state = followAudioOutput ? .on : .off
        followItem.toolTip = "When the Mac's audio output is a device with its own volume (AirPods, Bluetooth headphones, speakers), volume keys control it. When output is the TV over HDMI, keys control the TV."
        menu.addItem(followItem)

        let pauseItem = NSMenuItem(title: paused ? "Resume key hijack" : "Pause key hijack",
                                   action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let rescan = NSMenuItem(title: "Rescan network", action: #selector(rescan), keyEquivalent: "")
        rescan.target = self
        menu.addItem(rescan)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VolumeKey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func selectDevice(_ sender: NSMenuItem) {
        selectedUUID = sender.representedObject as? String
        // Selecting a TV connects right away (triggers the one-time pairing prompt if new).
        if let lg = selectedNetTarget as? LGTVConnection { lg.connect() }
        rebuildMenu()
    }

    @objc func pairTV(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String,
              let lg = netTargets.first(where: { $0.uuid == uuid }) as? LGTVConnection else { return }
        lg.connect()
        hud.showMessage("Check \(lg.name) for the pairing prompt")
    }
    @objc func setStep(_ sender: NSMenuItem) {
        stepSize = sender.representedObject as? Int ?? 3
        rebuildMenu()
    }
    @objc func micMuteClicked() {
        toggleMicMute()
    }
    @objc func toggleFollowAudio() {
        followAudioOutput.toggle()
        rebuildMenu()
    }
    @objc func togglePause() {
        paused.toggle()
        hijacker.enabled = !paused
        rebuildMenu()
    }
    @objc func rescan() {
        // Don't clear first — refresh in background, update zones in place when new data arrives.
        silentRefresh()
    }

    func silentRefresh(retriesLeft: Int = 0, expectChange: Bool = false) {
        startLGDiscovery()  // net targets too — updates IPs in place, appends new sets
        startRokuDiscovery()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.startDLNADiscovery()
        }
        let probe = SonosDiscovery()
        var collected: [SonosDevice] = []
        probe.onFound = { dev in
            if !collected.contains(where: { $0.uuid == dev.uuid }) {
                collected.append(dev)
            }
        }
        let snapshot = devices.map { "\($0.uuid):\($0.members.count)" }.sorted().joined(separator: ",")
        probe.onComplete = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if collected.isEmpty {
                    NSLog("VolumeKey: silentRefresh got 0 zones — keeping previous list")
                    return
                }
                let newSnap = collected.map { "\($0.uuid):\($0.members.count)" }.sorted().joined(separator: ",")
                let topologyUnchanged = newSnap == snapshot
                if expectChange && topologyUnchanged && retriesLeft > 0 {
                    NSLog("VolumeKey: silentRefresh — topology unchanged, retrying in 1.5s (\(retriesLeft) left)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.silentRefresh(retriesLeft: retriesLeft - 1, expectChange: true)
                    }
                    return
                }
                self.devices = collected
                self.rebuildMenu()
            }
        }
        probe.start()
    }

    var groupManagerWindows: [String: NSWindow] = [:]

    @objc func openGroupManager(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String,
              let zone = devices.first(where: { $0.uuid == uuid }) else { return }
        let w = groupManagerWindows[uuid] ?? {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                               styleMask: [.titled, .closable, .resizable],
                               backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.center()
            groupManagerWindows[uuid] = win
            return win
        }()
        w.title = "Group with \(zone.name)"
        w.contentView = GroupManagerView(zone: zone, allZones: devices, controller: controller) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self?.rescanThenRefreshGroupManager(uuid: uuid)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func rescanThenRefreshGroupManager(uuid: String) {
        devices.removeAll()
        rebuildMenu()
        let probe = SonosDiscovery()
        probe.onFound = { [weak self] dev in
            guard let self = self else { return }
            if !self.devices.contains(where: { $0.uuid == dev.uuid }) {
                self.devices.append(dev)
            }
        }
        probe.onComplete = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.rebuildMenu()
                if let w = self.groupManagerWindows[uuid],
                   let zone = self.devices.first(where: { $0.uuid == uuid }) {
                    w.contentView = GroupManagerView(zone: zone, allZones: self.devices,
                                                     controller: self.controller) { [weak self] in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            self?.rescanThenRefreshGroupManager(uuid: uuid)
                        }
                    }
                }
            }
        }
        probe.start()
    }

    @objc func ungroupAll(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String,
              let zone = devices.first(where: { $0.uuid == uuid }) else { return }
        let toLeave = zone.members.filter { $0.uuid != zone.uuid }
        let group = DispatchGroup()
        for m in toLeave {
            group.enter()
            controller.leaveGroup(leavingCoordinatorIP: m.ip) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self?.rescan() }
        }
    }

    var mixerWindow: NSWindow?
    @objc func openMixer() {
        if mixerWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "VolumeKey Mixer"
            w.isReleasedWhenClosed = false
            w.center()
            mixerWindow = w
        }
        if let w = mixerWindow {
            w.contentView = MixerView(devices: devices, controller: controller)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Menu submenu row: per-member volume slider

final class MemberVolumeRow: NSView {
    let member: SonosMember
    let controller: SonosController
    let isCoordinator: Bool
    let onUngroup: (() -> Void)?

    let checkbox: NSButton?
    let label = NSTextField(labelWithString: "")
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    let value = NSTextField(labelWithString: "0")

    init(member: SonosMember, controller: SonosController,
         isCoordinator: Bool = true, canUngroup: Bool = false,
         onUngroup: (() -> Void)? = nil) {
        self.member = member
        self.controller = controller
        self.isCoordinator = isCoordinator
        self.onUngroup = onUngroup
        if canUngroup {
            self.checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        } else {
            self.checkbox = nil
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 28))

        var labelX: CGFloat = 18
        if let cb = checkbox {
            cb.frame = NSRect(x: 18, y: 6, width: 16, height: 16)
            cb.state = .on
            cb.target = self
            cb.action = #selector(checkboxToggled)
            addSubview(cb)
            labelX = 38
        }

        label.frame = NSRect(x: labelX, y: 6, width: 132 - labelX, height: 16)
        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        slider.frame = NSRect(x: 132, y: 4, width: 140, height: 20)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        addSubview(slider)
        value.frame = NSRect(x: 278, y: 6, width: 32, height: 16)
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.alignment = .right
        addSubview(value)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func checkboxToggled() {
        // Only meaningful when unchecked — leave the group.
        if checkbox?.state == .off { onUngroup?() }
        // If user re-checks, no-op (re-grouping happens from another zone's submenu).
    }

    func refresh() {
        label.stringValue = member.name
        controller.getMemberVolume(member: member) { [weak self] v in
            DispatchQueue.main.async {
                guard let self = self, let v = v else { return }
                self.slider.doubleValue = Double(v)
                self.value.stringValue = "\(v)"
            }
        }
    }
    @objc func changed() {
        let v = Int(slider.doubleValue.rounded())
        value.stringValue = "\(v)"
        controller.setMemberVolume(member: member, volume: v) {}
    }
}

// MARK: - Mixer window: slider per member of every zone

final class MixerView: NSView {
    init(devices: [SonosDevice], controller: SonosController) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 480))
        let scroll = NSScrollView(frame: bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for d in devices.sorted(by: { $0.name < $1.name }) {
            let header = NSTextField(labelWithString: d.name)
            header.font = .boldSystemFont(ofSize: 13)
            stack.addArrangedSubview(header)
            for m in d.members {
                let row = MixerSliderRow(member: m, controller: controller)
                stack.addArrangedSubview(row)
            }
            stack.addArrangedSubview(MixerView.spacer())
        }

        let doc = NSView()
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        doc.frame = NSRect(x: 0, y: 0, width: bounds.width,
                           height: max(bounds.height, stack.fittingSize.height))
        scroll.documentView = doc
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }
    static func spacer() -> NSView {
        let v = NSView(); v.heightAnchor.constraint(equalToConstant: 8).isActive = true; return v
    }
}

// MARK: - Group checkbox row (lives inline in menu, doesn't dismiss it on click)
// Has a checkbox to add/remove from group, plus a slider to control that speaker's volume.

final class GroupCheckboxRow: NSView {
    private let checkbox: NSButton
    private let slider: NSSlider
    private let valueLabel: NSTextField
    private let onToggle: (Bool) -> Void
    private let coordMember: SonosMember
    private let controller: SonosController

    init(otherZone: SonosDevice, isMember: Bool, controller: SonosController,
         onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        self.controller = controller
        self.coordMember = SonosMember(name: otherZone.name, ip: otherZone.ip, uuid: otherZone.uuid)
        checkbox = NSButton(checkboxWithTitle: otherZone.name, target: nil, action: nil)
        slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
        valueLabel = NSTextField(labelWithString: "—")
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 22))

        checkbox.frame = NSRect(x: 18, y: 2, width: 110, height: 18)
        checkbox.state = isMember ? .on : .off
        checkbox.font = .menuFont(ofSize: 0)
        checkbox.target = self
        checkbox.action = #selector(handleCheck)
        checkbox.lineBreakMode = .byTruncatingTail
        addSubview(checkbox)

        slider.frame = NSRect(x: 132, y: 2, width: 130, height: 18)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(handleSlider)
        addSubview(slider)

        valueLabel.frame = NSRect(x: 268, y: 4, width: 36, height: 14)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.alignment = .right
        addSubview(valueLabel)

        // Fetch current volume for this speaker async.
        controller.getMemberVolume(member: coordMember) { [weak self] v in
            DispatchQueue.main.async {
                guard let self = self, let v = v else { return }
                self.slider.doubleValue = Double(v)
                self.valueLabel.stringValue = "\(v)"
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func handleCheck() {
        onToggle(checkbox.state == .on)
    }

    @objc func handleSlider() {
        let v = Int(slider.doubleValue.rounded())
        valueLabel.stringValue = "\(v)"
        controller.setMemberVolume(member: coordMember, volume: v) {}
    }

    func refresh() {
        controller.getMemberVolume(member: coordMember) { [weak self] v in
            DispatchQueue.main.async {
                guard let self = self, let v = v else { return }
                self.slider.doubleValue = Double(v)
                self.valueLabel.stringValue = "\(v)"
            }
        }
    }
}

// MARK: - Group manager window (legacy — replaced by inline checkboxes, kept for ⌘M mixer reuse)

final class GroupManagerView: NSView {
    let zone: SonosDevice
    let controller: SonosController
    let onChange: () -> Void

    init(zone: SonosDevice, allZones: [SonosDevice], controller: SonosController, onChange: @escaping () -> Void) {
        self.zone = zone
        self.controller = controller
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 400))

        let header = NSTextField(labelWithString: "“\(zone.name)” will play together with the rooms you check below.")
        header.font = .systemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor
        header.maximumNumberOfLines = 3
        header.lineBreakMode = .byWordWrapping
        header.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Currently-grouped member UUIDs (excludes the zone coordinator itself)
        let inGroup = Set(zone.members.map(\.uuid))

        // List ALL OTHER zones (other coordinator UUIDs). For each zone-coordinator that's already
        // joined to ours, the checkbox is on; toggling off makes it leave; toggling another on adds it.
        for other in allZones.sorted(by: { $0.name < $1.name }) where other.uuid != zone.uuid {
            let isMember = inGroup.contains(other.uuid)
            let cb = NSButton(checkboxWithTitle: other.name, target: self, action: #selector(toggle(_:)))
            cb.state = isMember ? .on : .off
            cb.identifier = NSUserInterfaceItemIdentifier(other.uuid)
            // Encode joining IP via tag→associated dict
            cb.toolTip = other.ip  // simple stash
            stack.addArrangedSubview(cb)
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let doc = FlippedView()
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor, constant: -8),
        ])
        doc.frame = NSRect(x: 0, y: 0, width: 300, height: max(80, stack.fittingSize.height + 16))
        scroll.documentView = doc

        addSubview(header)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func toggle(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let ip = sender.toolTip else { return }
        sender.isEnabled = false
        if sender.state == .on {
            // Joining: tell the OTHER zone's coordinator to join OUR coordinator's group.
            controller.joinGroup(joiningCoordinatorIP: ip, targetCoordinatorUUID: zone.uuid) { [weak self] in
                DispatchQueue.main.async { self?.onChange() }
            }
        } else {
            // Leaving: tell that zone to become standalone again.
            controller.leaveGroup(leavingCoordinatorIP: ip) { [weak self] in
                DispatchQueue.main.async { self?.onChange() }
            }
        }
        _ = id  // silence warning
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class MixerSliderRow: NSView {
    let member: SonosMember
    let controller: SonosController
    let label = NSTextField(labelWithString: "")
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    let value = NSTextField(labelWithString: "0")

    init(member: SonosMember, controller: SonosController) {
        self.member = member
        self.controller = controller
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        value.translatesAutoresizingMaskIntoConstraints = false
        value.alignment = .right
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.stringValue = member.name
        label.font = .systemFont(ofSize: 12)
        addSubview(label); addSubview(slider); addSubview(value)
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: 110),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.widthAnchor.constraint(equalToConstant: 32),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        controller.getMemberVolume(member: member) { [weak self] v in
            DispatchQueue.main.async {
                guard let self = self, let v = v else { return }
                self.slider.doubleValue = Double(v)
                self.value.stringValue = "\(v)"
            }
        }
    }
    @objc func changed() {
        let v = Int(slider.doubleValue.rounded())
        value.stringValue = "\(v)"
        controller.setMemberVolume(member: member, volume: v) {}
    }
}

// Bootstrap
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
