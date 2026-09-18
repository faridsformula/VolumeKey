import Cocoa
import Foundation

// MARK: - LG webOS TV support
//
// Controls LG TVs (webOS) over the local network via their WebSocket control
// API (wss://tv:3001) — the same channel the LG ThinQ phone app uses. Changes
// the TV's REAL volume (works with TV speakers and ARC/eARC soundbars alike).
// One-time pairing: the TV shows an on-screen prompt; the accepted client-key
// is stored in UserDefaults and reused forever after.

struct LGTVDevice {
    let name: String   // e.g. "OLED42C5PUA"
    let ip: String
    let uuid: String   // SSDP USN uuid — stable across reboots/DHCP changes
}

// MARK: - Discovery: SSDP M-SEARCH for the webOS second-screen service

final class LGTVDiscovery {
    var onFound: ((LGTVDevice) -> Void)?
    var onComplete: (() -> Void)?

    func start() {
        // NOTE: `self` is captured STRONGLY — discovery objects are created as
        // locals and must live until the search completes (closures are released
        // by SSDP.search afterwards, so there is no lasting cycle).
        SSDP.search(st: "urn:lge-com:service:webos-second-screen:1", onResponse: { text, host in
            guard text.contains("webos-second-screen"),
                  let loc = SSDP.headerValue(text, "Location"),
                  let url = URL(string: loc) else { return }
            let usn = SSDP.headerValue(text, "USN") ?? "uuid:\(host)"
            let uuid = Self.uuidFromUSN(usn) ?? host
            DispatchQueue.global(qos: .utility).async {
                let name = self.friendlyName(location: url, host: host) ?? "LG TV \(host)"
                let dev = LGTVDevice(name: name, ip: host, uuid: uuid)
                NSLog("VolumeKey: LG TV found: \(name) @ \(host)")
                DispatchQueue.main.async { self.onFound?(dev) }
            }
        }, onComplete: {
            self.onComplete?()
        })
    }

    // "uuid:15d89542-3ce4-ab56-7842-8ef61cd24690::urn:lge-com:..." → "15d89542-…"
    static func uuidFromUSN(_ usn: String) -> String? {
        guard usn.hasPrefix("uuid:") else { return nil }
        let after = usn.dropFirst(5)
        if let end = after.range(of: "::") { return String(after[..<end.lowerBound]) }
        return String(after)
    }

    private func friendlyName(location: URL, host: String) -> String? {
        let port = UInt16(location.port ?? 80)
        let path = location.path.isEmpty ? "/" : location.path
        guard let resp = RawHTTP.request(host: host, port: port, method: "GET", path: path,
                                         timeoutSec: 3),
              resp.status == 200,
              let r = resp.body.range(of: "<friendlyName>"),
              let e = resp.body.range(of: "</friendlyName>") else { return nil }
        var name = String(resp.body[r.upperBound..<e.lowerBound])
        name = name.replacingOccurrences(of: "[LG] webOS TV ", with: "")
        return name.isEmpty ? nil : "LG " + name
    }
}

// MARK: - Connection: WebSocket + pairing + audio control

final class LGTVConnection: NSObject, URLSessionWebSocketDelegate, VolumeTarget {
    enum State { case disconnected, connecting, pairing, ready }

    // VolumeTarget
    var uuid: String { device.uuid }
    var name: String { device.name }
    var ip: String { device.ip }
    let kindLabel = "TV"
    let supportsAbsoluteVolume = true

    private(set) var device: LGTVDevice
    private(set) var state: State = .disconnected
    private(set) var cachedVolume: Int?
    private(set) var cachedMuted = false
    private(set) var soundOutputRaw: String?

    /// True when the TV routes audio to an external device (eARC soundbar,
    /// optical, BT). In that mode webOS accepts `setVolume` (returnValue:true)
    /// but silently drops it — only volumeUp/volumeDown step commands are
    /// forwarded (as CEC) to the external device.
    var isExternalOutput: Bool {
        guard let so = soundOutputRaw else { return false }
        return !(so.contains("tv_speaker") || so.contains("headphone"))
    }

    /// Called on pairing prompt / connection failures — text for the HUD.
    var onUserMessage: ((String) -> Void)?
    /// Called whenever the TV reports a volume/mute change (incl. TV remote).
    var onAudioStatus: ((Int, Bool) -> Void)?

    private var session: URLSession!
    private var ws: URLSessionWebSocketTask?
    private var nextID = 1
    private var completions: [String: ([String: Any]?) -> Void] = [:]
    private var pendingActions: [() -> Void] = []
    private var triedPlaintextFallback = false
    private var triedMinimalManifest = false

    private var clientKeyDefaultsKey: String { "lgtv.clientKey.\(device.uuid)" }
    private var clientKey: String? {
        get { UserDefaults.standard.string(forKey: clientKeyDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: clientKeyDefaultsKey) }
    }

    init(device: LGTVDevice) {
        self.device = device
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func updateIP(_ ip: String) {
        guard ip != device.ip else { return }
        device = LGTVDevice(name: device.name, ip: ip, uuid: device.uuid)
        disconnect()
    }

    // MARK: Connect / register

    func connect() {
        guard state == .disconnected else { return }
        state = .connecting
        triedPlaintextFallback = false
        triedMinimalManifest = false
        open(url: URL(string: "wss://\(device.ip):3001")!)
    }

    private func open(url: URL) {
        NSLog("VolumeKey: LGTV connecting \(url)")
        let task = session.webSocketTask(with: url)
        ws = task
        task.resume()
        receiveLoop(task)
        register()
    }

    private func disconnect() {
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        state = .disconnected
        completions.removeAll()
    }

    private func failAndMaybeFallback(_ error: Error?) {
        // wss (3001) is right for current TVs; very old webOS only speaks ws://3000.
        if !triedPlaintextFallback, ws?.originalRequest?.url?.scheme == "wss" {
            triedPlaintextFallback = true
            NSLog("VolumeKey: LGTV wss failed (\(error?.localizedDescription ?? "?")) — trying ws://3000")
            ws?.cancel(with: .goingAway, reason: nil)
            state = .connecting
            open(url: URL(string: "ws://\(device.ip):3000")!)
            return
        }
        NSLog("VolumeKey: LGTV connection failed: \(error?.localizedDescription ?? "closed")")
        let hadPending = !pendingActions.isEmpty
        disconnect()
        pendingActions.removeAll()
        if hadPending {
            onUserMessage?("\(device.name) not responding — is the TV on?")
        }
    }

    private func register() {
        let manifest = triedMinimalManifest ? lgMinimalManifestJSON : lgPairingManifestJSON
        guard var payload = try? JSONSerialization.jsonObject(
            with: Data(manifest.utf8)) as? [String: Any] else { return }
        if let key = clientKey { payload["client-key"] = key }
        send(type: "register", id: "register_0", uri: nil, payload: payload)
    }

    // MARK: Receive loop

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self, self.ws === task else { return }
            switch result {
            case .failure(let err):
                DispatchQueue.main.async { self.failAndMaybeFallback(err) }
            case .success(let msg):
                var text: String?
                switch msg {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: break
                }
                if let text = text,
                   let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    DispatchQueue.main.async { self.handle(obj) }
                }
                self.receiveLoop(task)
            }
        }
    }

    private func handle(_ msg: [String: Any]) {
        let type = msg["type"] as? String ?? ""
        let id = msg["id"] as? String ?? ""
        let payload = msg["payload"] as? [String: Any]

        switch (type, id) {
        case ("registered", _):
            if let key = payload?["client-key"] as? String { clientKey = key }
            let wasPairing = state == .pairing
            state = .ready
            NSLog("VolumeKey: LGTV registered with \(device.name)")
            if wasPairing { onUserMessage?("\(device.name) paired ✓") }
            subscribeAudio()
            let actions = pendingActions
            pendingActions.removeAll()
            actions.forEach { $0() }

        case ("response", "register_0"):
            if (payload?["pairingType"] as? String) == "PROMPT" {
                state = .pairing
                NSLog("VolumeKey: LGTV pairing prompt shown on \(device.name)")
                onUserMessage?("Accept the connection prompt on \(device.name)")
            }

        case ("error", "register_0"):
            let errText = (msg["error"] as? String) ?? "unknown"
            NSLog("VolumeKey: LGTV register error: \(errText)")
            if clientKey != nil {
                // Stored key was revoked (e.g. TV reset) — re-pair from scratch.
                clientKey = nil
                register()
            } else if !triedMinimalManifest {
                // Firmware rejected the manifest itself (LG blacklisted the old
                // signed one in 2025; a future update could reject others) —
                // retry once with the smallest possible permission set before
                // giving up.
                triedMinimalManifest = true
                NSLog("VolumeKey: LGTV retrying registration with minimal manifest")
                register()
            } else {
                onUserMessage?("\(device.name) rejected pairing")
                disconnect()
            }

        case ("error", _):
            NSLog("VolumeKey: LGTV error for \(id): \((msg["error"] as? String) ?? "?")")
            completions.removeValue(forKey: id)?(nil)

        default:
            if id == "audio_status", let payload = payload {
                applyAudioStatus(payload)
            } else if let done = completions.removeValue(forKey: id) {
                done(payload)
            }
        }
    }

    // MARK: Requests

    private func send(type: String, id: String, uri: String?, payload: [String: Any]?) {
        var obj: [String: Any] = ["type": type, "id": id]
        if let uri = uri { obj["uri"] = uri }
        if let payload = payload { obj["payload"] = payload }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        ws?.send(.string(text)) { [weak self] err in
            if let err = err {
                DispatchQueue.main.async { self?.failAndMaybeFallback(err) }
            }
        }
    }

    private func request(_ uri: String, payload: [String: Any]? = nil,
                         completion: (([String: Any]?) -> Void)? = nil) {
        let id = "req_\(nextID)"; nextID += 1
        if let completion = completion { completions[id] = completion }
        send(type: "request", id: id, uri: uri, payload: payload)
    }

    private func subscribeAudio() {
        send(type: "subscribe", id: "audio_status", uri: "ssap://audio/getStatus", payload: nil)
    }

    // webOS has shipped two payload shapes over the years — handle both.
    // New: {"volumeStatus": {"volume": 12, "muteStatus": false, ...}}
    // Old: {"volume": 12, "mute"/"muted": false}
    private func applyAudioStatus(_ payload: [String: Any]) {
        var vol: Int?
        var mute: Bool?
        if let vs = payload["volumeStatus"] as? [String: Any] {
            vol = vs["volume"] as? Int
            mute = (vs["muteStatus"] as? Bool) ?? (vs["mute"] as? Bool)
            if let so = vs["soundOutput"] as? String { soundOutputRaw = so }
        } else {
            vol = payload["volume"] as? Int
            mute = (payload["mute"] as? Bool) ?? (payload["muted"] as? Bool)
            // Old webOS reports e.g. "mastervolume_ext_speaker_arc" here.
            if let sc = payload["scenario"] as? String { soundOutputRaw = sc }
        }
        if let v = vol { cachedVolume = v }
        if let m = mute { cachedMuted = m }
        if vol != nil || mute != nil {
            NSLog("VolumeKey: LGTV \(device.name) reports volume=\(cachedVolume.map(String.init) ?? "?") muted=\(cachedMuted)")
        }
        if let v = cachedVolume { onAudioStatus?(v, cachedMuted) }
    }

    /// Runs `action` now if connected, otherwise queues it and connects.
    private func whenReady(_ action: @escaping () -> Void) {
        if state == .ready { action(); return }
        pendingActions.append(action)
        if state == .disconnected { connect() }
        if state == .pairing { onUserMessage?("Accept the connection prompt on \(device.name)") }
    }

    // MARK: Public audio API

    /// Sends |delta| discrete volume presses — the only form the TV forwards
    /// to an external (eARC/optical/BT) audio device.
    private func step(by delta: Int) {
        let uri = delta >= 0 ? "ssap://audio/volumeUp" : "ssap://audio/volumeDown"
        for _ in 0..<min(abs(delta), 15) { request(uri) }
    }

    func bump(delta: Int, completion: @escaping (Int?, Bool) -> Void) {
        whenReady { [weak self] in
            guard let self = self else { return }
            if self.isExternalOutput {
                self.step(by: delta)
                if let cur = self.cachedVolume {
                    let target = max(0, min(100, cur + delta))
                    self.cachedVolume = target
                    completion(target, self.cachedMuted)
                } else {
                    completion(nil, self.cachedMuted)
                }
                return
            }
            if let cur = self.cachedVolume {
                let target = max(0, min(100, cur + delta))
                self.cachedVolume = target
                self.request("ssap://audio/setVolume", payload: ["volume": target])
                completion(target, false)
            } else {
                // No cache yet (subscription hasn't reported) — single hardware step.
                self.request(delta >= 0 ? "ssap://audio/volumeUp" : "ssap://audio/volumeDown") { _ in
                    self.request("ssap://audio/getVolume") { payload in
                        if let p = payload { self.applyAudioStatus(p) }
                        completion(self.cachedVolume, self.cachedMuted)
                    }
                }
            }
        }
    }

    func setVolume(_ volume: Int) {
        whenReady { [weak self] in
            guard let self = self else { return }
            let v = max(0, min(100, volume))
            if self.isExternalOutput {
                if let cur = self.cachedVolume, cur != v { self.step(by: v - cur) }
                self.cachedVolume = v
                return
            }
            self.cachedVolume = v
            self.request("ssap://audio/setVolume", payload: ["volume": v])
        }
    }

    func toggleMute(completion: @escaping (Int?, Bool) -> Void) {
        whenReady { [weak self] in
            guard let self = self else { return }
            let target = !self.cachedMuted
            self.cachedMuted = target
            self.request("ssap://audio/setMute", payload: ["mute": target])
            completion(self.cachedVolume, target)
        }
    }

    func refreshVolume(completion: ((Int?, Bool) -> Void)? = nil) {
        whenReady { [weak self] in
            guard let self = self else { return }
            self.request("ssap://audio/getVolume") { payload in
                if let p = payload { self.applyAudioStatus(p) }
                completion?(self.cachedVolume, self.cachedMuted)
            }
        }
    }

    // MARK: URLSessionWebSocketDelegate / TLS

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // LG TVs present a self-signed certificate on the LAN control port — accept it.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === ws else { return }
        DispatchQueue.main.async { self.failAndMaybeFallback(nil) }
    }
}

// MARK: - webOS pairing manifest (unsigned)
//
// Historically third-party apps registered with LG's leaked test-signing
// manifest (appId com.lge.test). 2025 firmware blacklists that certificate
// ("403 Pairing rejected: blacklisted certificate detected"), so we register
// with a plain unsigned manifest instead. The pairing prompt still appears and
// grants every permission below; only TEST_SECURE-class permissions (unused
// here) required the signed blob.

let lgPairingManifestJSON = """
{
  "forcePairing": false,
  "pairingType": "PROMPT",
  "manifest": {
    "manifestVersion": 1,
    "appVersion": "1.1",
    "permissions": [
      "CONTROL_AUDIO", "READ_APP_STATUS", "READ_CURRENT_CHANNEL",
      "READ_RUNNING_APPS", "READ_POWER_STATE", "READ_NETWORK_STATE",
      "READ_COUNTRY_INFO", "WRITE_NOTIFICATION_TOAST"
    ]
  }
}
"""

// Last-resort registration payload: audio control only. Used automatically if
// the TV rejects the manifest above, so one bad permission can never brick
// pairing outright.
let lgMinimalManifestJSON = """
{
  "forcePairing": false,
  "pairingType": "PROMPT",
  "manifest": {
    "manifestVersion": 1,
    "permissions": ["CONTROL_AUDIO", "READ_APP_STATUS"]
  }
}
"""
