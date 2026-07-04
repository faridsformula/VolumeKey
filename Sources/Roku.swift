import Foundation

// MARK: - Roku ECP (External Control Protocol)
//
// Covers Roku TVs (TCL, Hisense, Sharp, onn.) and Roku-connected soundbars.
// Plain REST on port 8060, no pairing. ECP has no volume READBACK, so these
// targets are relative-only: keys send VolumeUp/VolumeDown/VolumeMute presses
// and the HUD shows a chevron instead of a number. Requires the Roku setting
// "Control by mobile apps" (on by default).

final class RokuDevice: VolumeTarget {
    let uuid: String
    let name: String
    let ip: String
    let kindLabel = "Roku"
    let supportsAbsoluteVolume = false
    var cachedVolume: Int? { nil }

    init(uuid: String, name: String, ip: String) {
        self.uuid = uuid
        self.name = name
        self.ip = ip
    }

    private func keypress(_ key: String, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [ip] in
            _ = RawHTTP.request(host: ip, port: 8060, method: "POST",
                                path: "/keypress/\(key)", timeoutSec: 3)
            if let completion = completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    func bump(delta: Int, completion: @escaping (Int?, Bool) -> Void) {
        let key = delta >= 0 ? "VolumeUp" : "VolumeDown"
        let presses = max(1, abs(delta))
        DispatchQueue.global(qos: .userInitiated).async { [ip] in
            for _ in 0..<presses {
                _ = RawHTTP.request(host: ip, port: 8060, method: "POST",
                                    path: "/keypress/\(key)", timeoutSec: 3)
            }
            DispatchQueue.main.async { completion(nil, false) }
        }
    }

    func toggleMute(completion: @escaping (Int?, Bool) -> Void) {
        keypress("VolumeMute") { completion(nil, false) }
    }

    func setVolume(_ volume: Int) { /* ECP has no absolute volume */ }

    func refreshVolume(completion: ((Int?, Bool) -> Void)?) {
        completion?(nil, false)
    }
}

// MARK: - Discovery

final class RokuDiscovery {
    var onFound: ((RokuDevice) -> Void)?

    func start() {
        // Strong capture: keeps this discovery alive until the search completes.
        SSDP.search(st: "roku:ecp", onResponse: { text, host in
            guard let loc = SSDP.headerValue(text, "Location"),
                  let url = URL(string: loc), let ip = url.host else { return }
            let usn = SSDP.headerValue(text, "USN") ?? "uuid:roku:\(ip)"
            let uuid = LGTVDiscovery.uuidFromUSN(usn) ?? "roku:\(ip)"
            DispatchQueue.global(qos: .utility).async {
                guard let resp = RawHTTP.request(host: ip, port: 8060, method: "GET",
                                                 path: "/query/device-info", timeoutSec: 3),
                      resp.status == 200 else { return }
                let name = DLNARenderer.tagValue(resp.body, "friendly-device-name")
                    ?? DLNARenderer.tagValue(resp.body, "model-name")
                    ?? "Roku \(ip)"
                let dev = RokuDevice(uuid: uuid, name: name, ip: ip)
                NSLog("VolumeKey: Roku found: \(name) @ \(ip)")
                DispatchQueue.main.async { self.onFound?(dev) }
            }
        })
    }
}
