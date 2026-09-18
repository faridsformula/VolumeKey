import Cocoa

// MARK: - Update check (GitHub Releases)
//
// Shipped copies have no auto-update channel, so a breakage like LG's 2025
// certificate blacklist strands users on a build that can't pair. This checks
// the repo's latest-release tag once a day and surfaces a Download row in the
// menu plus a one-time HUD notice when a newer version exists. No
// auto-install, no telemetry — a single anonymous GET.

final class UpdateCheck {
    static let releasesAPI = URL(string: "https://api.github.com/repos/faridsformula/VolumeKey/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/faridsformula/VolumeKey/releases/latest")!

    private(set) var availableVersion: String?   // set when newer than the running build
    var onUpdateFound: ((String) -> Void)?
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func check() {
        var req = URLRequest(url: Self.releasesAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Self.isNewer(latest, than: self.currentVersion) else { return }
            DispatchQueue.main.async {
                guard self.availableVersion != latest else { return }
                self.availableVersion = latest
                NSLog("VolumeKey: update available — \(latest) (running \(self.currentVersion))")
                self.onUpdateFound?(latest)
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
