import Foundation

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var displayVersion: String { "v" + version }
}

@MainActor
final class UpdateChecker: ObservableObject {
    private static let endpoint = URL(string: "https://api.github.com/repos/sratabix/awsssh/releases/latest")!
    private static let pollInterval: TimeInterval = 6 * 60 * 60

    @Published private(set) var latestVersion: String?
    private var isChecking = false

    private var timer: Timer?

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

        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let tag = data.flatMap(Self.parseTag)
            Task { @MainActor in
                guard let self else { return }
                self.isChecking = false
                guard let tag, Self.isNewer(remote: tag, current: AppInfo.version) else { return }
                self.latestVersion = tag
            }
        }.resume()
    }

    nonisolated static func parseTag(_ data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = object["tag_name"] as? String
        else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
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
