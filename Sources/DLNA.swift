import Foundation

// MARK: - DLNA/UPnP MediaRenderer volume control
//
// The standard RenderingControl service exposed by Samsung, Sony, Philips,
// and Panasonic TVs, plus most network AVRs and soundbars (Denon, Yamaha,
// Onkyo…). Discovery PROBES each renderer with a GetVolume and only surfaces
// devices that actually authorize volume actions — some brands (LG: error
// 606) lock RenderingControl to active casting sessions and are covered by
// their native backend instead.

final class DLNARenderer: VolumeTarget {
    let uuid: String
    let name: String
    let ip: String
    let kindLabel = "TV"
    let supportsAbsoluteVolume = true
    private(set) var cachedVolume: Int?
    private var cachedMuted = false

    private let port: UInt16
    private let controlPath: String

    init(uuid: String, name: String, ip: String, port: UInt16, controlPath: String, initialVolume: Int?) {
        self.uuid = uuid
        self.name = name
        self.ip = ip
        self.port = port
        self.controlPath = controlPath
        self.cachedVolume = initialVolume
    }

    // MARK: VolumeTarget

    func bump(delta: Int, completion: @escaping (Int?, Bool) -> Void) {
        if let cur = cachedVolume {
            let target = max(0, min(100, cur + delta))
            cachedVolume = target
            soap(action: "SetVolume", extraArgs: "<DesiredVolume>\(target)</DesiredVolume>") { _ in }
            completion(target, false)
        } else {
            refreshVolume { [weak self] vol, muted in
                guard let self = self, let vol = vol else { completion(nil, false); return }
                let target = max(0, min(100, vol + delta))
                self.cachedVolume = target
                self.soap(action: "SetVolume", extraArgs: "<DesiredVolume>\(target)</DesiredVolume>") { _ in }
                completion(target, muted)
            }
        }
    }

    func setVolume(_ volume: Int) {
        let v = max(0, min(100, volume))
        cachedVolume = v
        soap(action: "SetVolume", extraArgs: "<DesiredVolume>\(v)</DesiredVolume>") { _ in }
    }

    func toggleMute(completion: @escaping (Int?, Bool) -> Void) {
        soap(action: "GetMute", extraArgs: "") { [weak self] xml in
            guard let self = self else { return }
            let current = xml.flatMap { Self.tagValue($0, "CurrentMute") } == "1"
            let target = !current
            self.cachedMuted = target
            self.soap(action: "SetMute", extraArgs: "<DesiredMute>\(target ? "1" : "0")</DesiredMute>") { _ in
                DispatchQueue.main.async { completion(self.cachedVolume, target) }
            }
        }
    }

    func refreshVolume(completion: ((Int?, Bool) -> Void)?) {
        soap(action: "GetVolume", extraArgs: "") { [weak self] xml in
            let vol = xml.flatMap { Self.tagValue($0, "CurrentVolume") }.flatMap(Int.init)
            DispatchQueue.main.async {
                if let v = vol { self?.cachedVolume = v }
                completion?(self?.cachedVolume, self?.cachedMuted ?? false)
            }
        }
    }

    // MARK: SOAP

    private func soap(action: String, extraArgs: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [ip, port, controlPath] in
            let resp = Self.soapRequest(ip: ip, port: port, path: controlPath,
                                        action: action, extraArgs: extraArgs)
            completion(resp)
        }
    }

    /// Static so discovery can probe before constructing a renderer. Returns the
    /// response body on HTTP 200 with no UPnP fault, nil otherwise.
    static func soapRequest(ip: String, port: UInt16, path: String,
                            action: String, extraArgs: String) -> String? {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel>\(extraArgs)</u:\(action)></s:Body>
        </s:Envelope>
        """
        guard let resp = RawHTTP.request(
            host: ip, port: port, method: "POST", path: path,
            headers: [
                "Content-Type": "text/xml; charset=\"utf-8\"",
                "SOAPACTION": "\"urn:schemas-upnp-org:service:RenderingControl:1#\(action)\""
            ],
            body: body, timeoutSec: 4),
            resp.status == 200, !resp.body.contains("<s:Fault") else { return nil }
        return resp.body
    }

    static func tagValue(_ xml: String, _ tag: String) -> String? {
        guard let r = xml.range(of: "<\(tag)>"), let e = xml.range(of: "</\(tag)>") else { return nil }
        return String(xml[r.upperBound..<e.lowerBound])
    }
}

// MARK: - Discovery

final class DLNADiscovery {
    var onFound: ((DLNARenderer) -> Void)?

    /// `excludedIPs`: devices already handled by a native backend (LG webOS,
    /// Sonos) — their renderers are skipped.
    func start(excludedIPs: Set<String>) {
        // Strong capture: keeps this discovery alive until the search completes.
        SSDP.search(st: "urn:schemas-upnp-org:device:MediaRenderer:1", onResponse: { text, host in
            guard !excludedIPs.contains(host),
                  let loc = SSDP.headerValue(text, "Location"),
                  let url = URL(string: loc), let descHost = url.host,
                  !excludedIPs.contains(descHost) else { return }
            let usn = SSDP.headerValue(text, "USN") ?? "uuid:\(host)"
            let uuid = LGTVDiscovery.uuidFromUSN(usn) ?? host
            DispatchQueue.global(qos: .utility).async {
                self.probe(url: url, host: descHost, uuid: uuid)
            }
        })
    }

    private func probe(url: URL, host: String, uuid: String) {
        let port = UInt16(url.port ?? 80)
        let path = url.path.isEmpty ? "/" : url.path
        guard let resp = RawHTTP.request(host: host, port: port, method: "GET",
                                         path: path, timeoutSec: 4),
              resp.status == 200 else { return }
        let desc = resp.body

        // Sonos zones have a native backend with grouping — skip their renderers.
        if desc.contains("Sonos") { return }

        guard let controlPath = Self.renderingControlPath(desc) else { return }
        var name = DLNARenderer.tagValue(desc, "friendlyName") ?? "TV \(host)"
        name = name.replacingOccurrences(of: "[TV] ", with: "")  // Samsung prefixes

        // The gate: only devices that AUTHORIZE volume control become targets.
        guard let volXML = DLNARenderer.soapRequest(ip: host, port: port, path: controlPath,
                                                    action: "GetVolume", extraArgs: ""),
              let vol = DLNARenderer.tagValue(volXML, "CurrentVolume").flatMap(Int.init) else {
            NSLog("VolumeKey: DLNA renderer '\(name)' @ \(host) refused GetVolume — skipping")
            return
        }
        let renderer = DLNARenderer(uuid: uuid, name: name, ip: host, port: port,
                                    controlPath: controlPath, initialVolume: vol)
        NSLog("VolumeKey: DLNA renderer found: \(name) @ \(host) (volume \(vol))")
        DispatchQueue.main.async { self.onFound?(renderer) }
    }

    /// Extracts the RenderingControl service's controlURL from a device description.
    static func renderingControlPath(_ desc: String) -> String? {
        var idx = desc.startIndex
        while let sStart = desc.range(of: "<service>", range: idx..<desc.endIndex),
              let sEnd = desc.range(of: "</service>", range: sStart.upperBound..<desc.endIndex) {
            let block = String(desc[sStart.upperBound..<sEnd.lowerBound])
            idx = sEnd.upperBound
            guard block.contains("RenderingControl") else { continue }
            guard var path = DLNARenderer.tagValue(block, "controlURL") else { continue }
            // controlURL may be absolute ("http://ip:port/x") or relative ("/x" or "x")
            if let u = URL(string: path), u.host != nil { path = u.path }
            if !path.hasPrefix("/") { path = "/" + path }
            return path
        }
        return nil
    }
}
