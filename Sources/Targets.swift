import Foundation

// MARK: - VolumeTarget
//
// Anything the volume keys can drive over the network or display cable.
// Sonos zones predate this protocol and keep their own richer path (groups,
// satellites, mixer); everything else — LG webOS, DLNA renderers, Roku,
// DDC displays — conforms to this.

protocol VolumeTarget: AnyObject {
    var uuid: String { get }          // stable identity (persisted as the selected target)
    var name: String { get }          // menu title, e.g. "LG OLED42C5PUA" / "Samsung Q80B"
    var kindLabel: String { get }     // HUD prefix: "TV", "Display", "Roku"
    var ip: String { get }            // for cross-backend dedupe ("" if not networked)

    /// False for targets with no readable level (Roku ECP) — no slider, chevron HUD.
    var supportsAbsoluteVolume: Bool { get }
    var cachedVolume: Int? { get }

    /// Completion delivers the resulting volume (nil if unknown) and mute state.
    func bump(delta: Int, completion: @escaping (Int?, Bool) -> Void)
    func toggleMute(completion: @escaping (Int?, Bool) -> Void)
    func setVolume(_ volume: Int)
    func refreshVolume(completion: ((Int?, Bool) -> Void)?)
}

// MARK: - Shared SSDP search

enum SSDP {
    /// Sends an M-SEARCH for `st` and calls `onResponse` with each raw response
    /// (from unique hosts) until `seconds` elapse. Callbacks fire on the main queue.
    static func search(st: String, seconds: Double = 3.0,
                       onResponse: @escaping (_ response: String, _ host: String) -> Void,
                       onComplete: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard sock >= 0 else { DispatchQueue.main.async { onComplete?() }; return }
            defer { Darwin.close(sock) }
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(1900).bigEndian
            _ = inet_pton(AF_INET, "239.255.255.250", &addr.sin_addr)

            let msearch = ["M-SEARCH * HTTP/1.1",
                           "HOST: 239.255.255.250:1900",
                           "MAN: \"ssdp:discover\"",
                           "MX: 2",
                           "ST: \(st)",
                           "", ""].joined(separator: "\r\n")
            let bytes = Array(msearch.utf8)
            for _ in 0..<2 {  // UDP — send twice, datagrams get dropped
                _ = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        bytes.withUnsafeBufferPointer { buf in
                            Darwin.sendto(sock, buf.baseAddress, buf.count, 0, sa,
                                          socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                usleep(100_000)
            }

            var seen = Set<String>()
            let deadline = Date().addingTimeInterval(seconds)
            var buf = [UInt8](repeating: 0, count: 4096)
            while Date() < deadline {
                var from = sockaddr_in()
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(sock, &buf, buf.count, 0, sa, &fromLen)
                    }
                }
                if n <= 0 { break }
                var hostBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &from.sin_addr, &hostBuf, socklen_t(INET_ADDRSTRLEN))
                let host = String(cString: hostBuf)
                guard !seen.contains(host),
                      let text = String(bytes: buf[0..<n], encoding: .utf8) else { continue }
                seen.insert(host)
                DispatchQueue.main.async { onResponse(text, host) }
            }
            DispatchQueue.main.async { onComplete?() }
        }
    }

    static func headerValue(_ response: String, _ name: String) -> String? {
        for line in response.split(separator: "\r\n") {
            if let colon = line.firstIndex(of: ":"),
               line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

// MARK: - Menu row: generic target volume slider

import Cocoa

final class TargetVolumeRow: NSView {
    private let target: VolumeTarget
    private let label = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let value = NSTextField(labelWithString: "—")

    init(target: VolumeTarget) {
        self.target = target
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        label.stringValue = "Volume"
        label.frame = NSRect(x: 18, y: 6, width: 114, height: 16)
        label.font = .menuFont(ofSize: 0)
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
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        if let v = target.cachedVolume {
            slider.doubleValue = Double(v)
            value.stringValue = "\(v)"
        }
        // Passive UI must not initiate connections/pairing — only query live LG links.
        if let lg = target as? LGTVConnection, lg.state != .ready { return }
        target.refreshVolume { [weak self] v, _ in
            DispatchQueue.main.async {
                guard let self = self, let v = v else { return }
                self.slider.doubleValue = Double(v)
                self.value.stringValue = "\(v)"
            }
        }
    }

    @objc private func changed() {
        let v = Int(slider.doubleValue.rounded())
        value.stringValue = "\(v)"
        target.setVolume(v)
    }
}
