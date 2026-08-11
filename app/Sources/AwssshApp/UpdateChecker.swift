import Foundation

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var displayVersion: String { "v" + version }

    nonisolated static func isRelease(_ version: String) -> Bool {
        !version.contains("-") && UpdateChecker.isNewer(remote: version, current: "0.0.0")
    }

    static var userAgent: String { "Awsssh/" + version }
}

struct ReleaseAsset: Equatable {
    let url: URL
    let sha256: String
}

struct Release: Equatable {
    let version: String
    let page: URL?
    let asset: ReleaseAsset?
}

private let releaseEndpoint = URL(string: "https://api.github.com/repos/sratabix/awsssh/releases/latest")!
private let hexDigits = Set("0123456789abcdef")

@MainActor
final class UpdateChecker: ObservableObject {
    private static let pollInterval: TimeInterval = 6 * 60 * 60

    @Published private(set) var latest: Release?
    private var isChecking = false

    private var timer: Timer?

    var available: Release? {
        guard let latest, Self.isNewer(remote: latest.version, current: AppInfo.version) else { return nil }
        return latest
    }

    func start() {
        guard timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func check() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let release = await fetchLatest()
            isChecking = false
            guard let release else { return }
            latest = release
        }
    }

    func adopt(_ release: Release) {
        latest = release
    }

    func fetchLatest() async -> Release? {
        guard let (data, _) = try? await URLSession.shared.data(for: Self.request()) else { return nil }
        return Self.parseRelease(data)
    }

    nonisolated private static func request() -> URLRequest {
        var request = URLRequest(url: releaseEndpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
    }

    nonisolated static func parseRelease(_ data: Data) -> Release? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = object["tag_name"] as? String,
            object["prerelease"] as? Bool != true
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(
            version: version,
            page: (object["html_url"] as? String).flatMap { URL(string: $0) },
            asset: parseAsset(object, version: version)
        )
    }

    nonisolated private static func parseAsset(_ object: [String: Any], version: String) -> ReleaseAsset? {
        guard
            let assets = object["assets"] as? [[String: Any]],
            let entry = assets.first(where: { $0["name"] as? String == "Awsssh-\(version).zip" }),
            let raw = entry["browser_download_url"] as? String,
            let url = URL(string: raw),
            Installer.isTrustedDownload(url),
            let digest = entry["digest"] as? String,
            digest.hasPrefix("sha256:")
        else { return nil }
        let hex = String(digest.dropFirst(7)).lowercased()
        guard hex.count == 64, hex.allSatisfy(hexDigits.contains) else { return nil }
        return ReleaseAsset(url: url, sha256: hex)
    }

    nonisolated static func parseTag(_ data: Data) -> String? {
        parseRelease(data)?.version
    }

    nonisolated static func isNewer(remote: String, current: String) -> Bool {
        let a = components(remote), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    nonisolated private static func components(_ version: String) -> [Int] {
        guard let release = version.split(separator: "-", maxSplits: 1).first else { return [] }
        return
            release
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
