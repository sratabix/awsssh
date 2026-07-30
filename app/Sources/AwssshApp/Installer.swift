import AppKit
import CryptoKit
import Foundation

private let trustedHosts: Set<String> = [
    "github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
]

@MainActor
final class Installer: ObservableObject {
    static let bundleID = "com.github.sratabix.awsssh"
    static let bundleName = "Awsssh.app"

    enum Phase: Equatable {
        case idle
        case resolving
        case downloading(String)
        case verifying
        case installing
        case failed(String)
        case blocked(String)
    }

    @Published private(set) var phase: Phase = .idle

    var fetchLatest: () async -> Release? = { nil }
    var adopt: (Release) -> Void = { _ in }
    var quit: () -> Void = { NSApp.terminate(nil) }

    var busy: Bool {
        switch phase {
        case .idle, .failed, .blocked: return false
        case .resolving, .downloading, .verifying, .installing: return true
        }
    }

    func dismiss() {
        guard !busy else { return }
        phase = .idle
    }

    func install(_ release: Release) {
        if !busy { phase = .idle }
        guard case .idle = phase else { return }
        guard release.asset != nil else {
            phase = .failed("This release has no verifiable download. Update with brew upgrade --cask awsssh.")
            return
        }

        let bundle = Bundle.main.bundleURL
        let files = FileManager.default
        guard files.fileExists(atPath: bundle.path) else {
            phase = .blocked("Awsssh cannot find its own bundle. Update with brew upgrade --cask awsssh.")
            return
        }
        guard files.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            phase = .blocked(
                "No permission to replace \(bundle.path). Update with brew upgrade --cask awsssh."
            )
            return
        }

        phase = .resolving
        Task { await perform(release, bundle: bundle) }
    }

    private func perform(_ release: Release, bundle: URL) async {
        var work: URL?
        do {
            let target = await resolve(release)
            guard let asset = target.asset else {
                throw Failure("This release has no verifiable download.")
            }

            phase = .downloading(target.version)
            let dir = try makeWorkDir()
            work = dir
            let zip = try await download(asset.url, into: dir)

            phase = .verifying
            let digest = try Installer.sha256(of: zip)
            guard digest == asset.sha256 else {
                throw Failure(
                    "Checksum mismatch — refusing to install. "
                        + "Expected \(asset.sha256.prefix(12))…, got \(digest.prefix(12))…."
                )
            }
            let app = try await verifiedBundle(from: zip, in: dir, expecting: target.version)

            phase = .installing
            try launchSwap(newApp: app, currentApp: bundle, work: dir)
            try? await Task.sleep(nanoseconds: 250_000_000)
            quit()
        } catch {
            if let work { try? FileManager.default.removeItem(at: work) }
            phase = .failed(error.localizedDescription)
        }
    }

    private func resolve(_ release: Release) async -> Release {
        guard
            let latest = await fetchLatest(),
            latest.asset != nil,
            UpdateChecker.isNewer(remote: latest.version, current: release.version)
        else { return release }
        adopt(latest)
        return latest
    }

    private func makeWorkDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("awsssh-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func download(_ url: URL, into dir: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300

        let (temp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure("Download failed with HTTP \(http.statusCode).")
        }
        let dest = dir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    private func verifiedBundle(from zip: URL, in dir: URL, expecting version: String) async throws -> URL {
        let listing = try await run("/usr/bin/unzip", ["-Z1", zip.path])
        if let bad = Installer.unsafeEntry(in: listing.split(separator: "\n").map(String.init)) {
            throw Failure("Archive contains an unsafe path: \(bad)")
        }

        let out = dir.appendingPathComponent("extracted", isDirectory: true)
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])

        let apps = try FileManager.default
            .contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, apps[0].lastPathComponent == Installer.bundleName else {
            throw Failure("Expected exactly one \(Installer.bundleName) in the download.")
        }
        let app = apps[0]

        guard let info = Bundle(url: app), info.bundleIdentifier == Installer.bundleID else {
            throw Failure("Downloaded app is not \(Installer.bundleID).")
        }
        let shipped = info.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard shipped == version else {
            throw Failure("Downloaded app reports version \(shipped), expected \(version).")
        }

        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    private func launchSwap(newApp: URL, currentApp: URL, work: URL) throws {
        let script = Installer.makeSwapScript(
            pid: ProcessInfo.processInfo.processIdentifier,
            newApp: newApp.path,
            currentApp: currentApp.path,
            work: work.path
        )
        let url = work.appendingPathComponent("swap.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [url.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        try task.run()
    }

    nonisolated static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return trustedHosts.contains(host)
    }

    nonisolated static func unsafeEntry(in entries: [String]) -> String? {
        entries.first {
            $0.hasPrefix("/")
                || $0 == ".."
                || $0.hasPrefix("../")
                || $0.contains("/../")
                || $0.hasSuffix("/..")
        }
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func makeSwapScript(pid: Int32, newApp: String, currentApp: String, work: String) -> String {
        """
        #!/bin/bash
        set -e
        NEW=\(quoted(newApp))
        OLD=\(quoted(currentApp))
        BACKUP="${OLD}.awsssh-backup"

        for _ in $(seq 1 60); do
            kill -0 \(pid) 2>/dev/null || break
            sleep 0.5
        done

        rm -rf "$BACKUP"
        mv "$OLD" "$BACKUP"

        if mv "$NEW" "$OLD"; then
            /usr/bin/xattr -dr com.apple.quarantine "$OLD" || true
            open "$OLD"
            sleep 2
            rm -rf "$BACKUP"
        else
            rm -rf "$OLD"
            mv "$BACKUP" "$OLD"
            open "$OLD"
        fi

        rm -rf \(quoted(work))
        """
    }

    nonisolated private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) async throws -> String {
        let result = try await Installer.spawn(path, arguments)
        guard result.status == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw Failure(
                "\(path) failed (\(result.status)): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return result.stdout
    }

    private struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    nonisolated private static func spawn(_ path: String, _ arguments: [String]) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: path)
                task.arguments = arguments

                let outPipe = Pipe(), errPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe
                task.standardInput = FileHandle.nullDevice

                do {
                    try task.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let group = DispatchGroup()
                var errData = Data()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                task.waitUntilExit()

                continuation.resume(
                    returning: Output(
                        status: task.terminationStatus,
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? ""
                    )
                )
            }
        }
    }
}

private struct Failure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
