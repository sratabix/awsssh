import XCTest
@testable import AwssshApp

final class InstallerTests: XCTestCase {
    func testTrustedDownloadAcceptsGitHubHosts() {
        for host in ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"] {
            XCTAssertTrue(Installer.isTrustedDownload(URL(string: "https://\(host)/a.zip")!), host)
        }
    }

    func testTrustedDownloadRejectsOtherHostsAndSchemes() {
        XCTAssertFalse(Installer.isTrustedDownload(URL(string: "http://github.com/a.zip")!))
        XCTAssertFalse(Installer.isTrustedDownload(URL(string: "https://evil.example/a.zip")!))
        XCTAssertFalse(Installer.isTrustedDownload(URL(string: "https://github.com.evil.example/a.zip")!))
        XCTAssertFalse(Installer.isTrustedDownload(URL(string: "https://notgithub.com/a.zip")!))
        XCTAssertFalse(Installer.isTrustedDownload(URL(string: "file:///tmp/a.zip")!))
    }

    func testUnsafeEntryFlagsTraversalAndAbsolutePaths() {
        XCTAssertEqual(Installer.unsafeEntry(in: ["/etc/passwd"]), "/etc/passwd")
        XCTAssertEqual(Installer.unsafeEntry(in: ["../outside"]), "../outside")
        XCTAssertEqual(Installer.unsafeEntry(in: ["Awsssh.app/../../x"]), "Awsssh.app/../../x")
        XCTAssertEqual(Installer.unsafeEntry(in: ["Awsssh.app/.."]), "Awsssh.app/..")
        XCTAssertEqual(Installer.unsafeEntry(in: [".."]), "..")
    }

    func testUnsafeEntryAcceptsARealBundleListing() {
        let entries = [
            "Awsssh.app/",
            "Awsssh.app/Contents/",
            "Awsssh.app/Contents/Info.plist",
            "Awsssh.app/Contents/_CodeSignature/CodeResources",
            "Awsssh.app/Contents/MacOS/Awsssh",
            "Awsssh.app/Contents/Resources/._awsssh",
            "Awsssh.app/Contents/Resources/completions/_awsssh",
        ]
        XCTAssertNil(Installer.unsafeEntry(in: entries))
    }

    func testSHA256MatchesKnownDigest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(
            try Installer.sha256(of: url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testSHA256HashesBeyondOneChunk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-sha-big-\(UUID().uuidString)")
        try Data(repeating: 0x61, count: (1 << 20) + 7).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let digest = try Installer.sha256(of: url)
        XCTAssertEqual(digest.count, 64)
        XCTAssertNotEqual(digest, try Installer.sha256(of: writeTemp(Data(repeating: 0x61, count: 1 << 20))))
    }

    func testSwapScriptCleansOnlyTheWorkDir() {
        let script = Installer.makeSwapScript(
            pid: 4242,
            newApp: "/tmp/awsssh-update-1/extracted/Awsssh.app",
            currentApp: "/Applications/Awsssh.app",
            work: "/tmp/awsssh-update-1"
        )
        XCTAssertTrue(script.contains("rm -rf '/tmp/awsssh-update-1'"))
        XCTAssertFalse(script.contains("rm -rf '/tmp'"))
        XCTAssertFalse(script.contains("dirname"))
    }

    func testSwapScriptWaitsForTheRunningAppThenBacksItUp() {
        let script = Installer.makeSwapScript(
            pid: 4242,
            newApp: "/tmp/new/Awsssh.app",
            currentApp: "/Applications/Awsssh.app",
            work: "/tmp/new"
        )
        XCTAssertTrue(script.contains("kill -0 4242"))
        XCTAssertTrue(script.contains("BACKUP=\"${OLD}.awsssh-backup\""))
        XCTAssertTrue(script.contains("mv \"$OLD\" \"$BACKUP\""))
        XCTAssertTrue(script.contains("mv \"$BACKUP\" \"$OLD\""))
        XCTAssertTrue(script.contains("com.apple.quarantine"))
        XCTAssertTrue(script.contains("open \"$OLD\""))
    }

    func testSwapScriptQuotesPathsWithSpacesAndQuotes() {
        let script = Installer.makeSwapScript(
            pid: 1,
            newApp: "/tmp/a b/Awsssh.app",
            currentApp: "/Applications/It's Awsssh.app",
            work: "/tmp/a b"
        )
        XCTAssertTrue(script.contains("NEW='/tmp/a b/Awsssh.app'"))
        XCTAssertTrue(script.contains(#"OLD='/Applications/It'\''s Awsssh.app'"#))
    }

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-sha-tmp-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }
}

extension InstallerTests {
    func testSwapScriptNeutralisesShellMetacharactersInPaths() {
        let nasty = "/tmp/$(touch /tmp/pwned)/Awsssh.app"
        let script = Installer.makeSwapScript(
            pid: 1, newApp: nasty, currentApp: "/Applications/Awsssh.app", work: "/tmp/w")
        XCTAssertTrue(
            script.contains("NEW='/tmp/$(touch /tmp/pwned)/Awsssh.app'"),
            "command substitution must sit inside single quotes where the shell will not run it")
        XCTAssertFalse(script.contains("NEW=/tmp/$("), "the path must never be unquoted")
    }

    func testSwapScriptNeutralisesBackticksAndSemicolons() {
        for nasty in ["/tmp/`id`/A.app", "/tmp/a;rm -rf ~/b/A.app", "/tmp/a&&whoami/A.app", "/tmp/a|tee/A.app"] {
            let script = Installer.makeSwapScript(
                pid: 1, newApp: nasty, currentApp: "/Applications/Awsssh.app", work: "/tmp/w")
            XCTAssertTrue(script.contains("NEW='\(nasty)'"), "\(nasty) must be single quoted verbatim")
        }
    }

    func testSwapScriptIsValidBashForAwkwardPaths() throws {
        let paths = [
            "/Applications/Awsssh.app",
            "/tmp/it's/Awsssh.app",
            "/tmp/a b/Awsssh.app",
            "/tmp/$(touch pwned)/Awsssh.app",
            "/tmp/`id`/Awsssh.app",
            "/tmp/a;rm -rf x/Awsssh.app",
            "/tmp/quote\"double/Awsssh.app",
        ]
        for path in paths {
            let script = Installer.makeSwapScript(
                pid: 1, newApp: path, currentApp: path, work: "/tmp/work")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("swap-\(UUID().uuidString).sh")
            try script.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-n", url.path]
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            XCTAssertEqual(
                task.terminationStatus, 0,
                "bash -n rejected the script generated for \(path.debugDescription)")
        }
    }

    func testSwapScriptRefusesToWidenCleanupToTheTempRoot() {
        let script = Installer.makeSwapScript(
            pid: 1,
            newApp: "/var/folders/xy/awsssh-update-1/extracted/Awsssh.app",
            currentApp: "/Applications/Awsssh.app",
            work: "/var/folders/xy/awsssh-update-1")
        XCTAssertTrue(script.contains("rm -rf '/var/folders/xy/awsssh-update-1'"))
        XCTAssertFalse(script.contains("rm -rf '/var/folders/xy'"))
        XCTAssertFalse(script.contains("rm -rf '/var/folders'"))
        XCTAssertFalse(script.contains("$TMPDIR"))
    }

    func testSwapScriptFailsFastAndNeverTouchesTheAppBeforeWaiting() {
        let script = Installer.makeSwapScript(
            pid: 4242, newApp: "/tmp/n/A.app", currentApp: "/Applications/A.app", work: "/tmp/n")
        XCTAssertTrue(script.hasPrefix("#!/bin/bash\nset -e"), "the script must be strict from line one")

        let waitAt = try? XCTUnwrap(script.range(of: "kill -0 4242")?.lowerBound)
        let moveAt = try? XCTUnwrap(script.range(of: "mv \"$OLD\"")?.lowerBound)
        if let waitAt, let moveAt {
            XCTAssertLessThan(waitAt, moveAt, "the bundle must not be moved before our pid is gone")
        }
    }

    func testTrustedDownloadRejectsCredentialsAndOddAuthorities() {
        let rejected = [
            "https://user:pass@evil.example/a.zip",
            "https://github.com@evil.example/a.zip",
            "https://",
            "https://127.0.0.1/a.zip",
            "https://localhost/a.zip",
            "ftp://github.com/a.zip",
            "javascript:alert(1)",
        ]
        for raw in rejected {
            guard let url = URL(string: raw) else { continue }
            XCTAssertFalse(Installer.isTrustedDownload(url), "\(raw) must not be trusted")
        }
    }

    func testTrustedDownloadIgnoresHostCase() {
        let url = URL(string: "https://GitHub.COM/sratabix/awsssh/releases/download/v1/A.zip")!
        XCTAssertTrue(Installer.isTrustedDownload(url), "host comparison must be case insensitive")
    }

    func testUnsafeEntryAcceptsALeadingDotSlash() {
        XCTAssertNil(Installer.unsafeEntry(in: ["./Awsssh.app/Contents/Info.plist"]))
    }

    func testUnsafeEntryFindsTheFirstOffenderNotTheLast() {
        let entries = ["Awsssh.app/ok", "../first", "/second"]
        XCTAssertEqual(Installer.unsafeEntry(in: entries), "../first")
    }

    func testUnsafeEntryOnAnEmptyListing() {
        XCTAssertNil(Installer.unsafeEntry(in: []))
        XCTAssertNil(Installer.unsafeEntry(in: [""]))
    }

    func testSHA256OfAnEmptyFileIsTheKnownEmptyDigest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-empty-\(UUID().uuidString)")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(
            try Installer.sha256(of: url),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSHA256IsStableAcrossChunkBoundaries() throws {
        for size in [(1 << 20) - 1, 1 << 20, (1 << 20) + 1] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("installer-chunk-\(size)-\(UUID().uuidString)")
            try Data(repeating: 0x5A, count: size).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let digest = try Installer.sha256(of: url)
            XCTAssertEqual(digest.count, 64, "size \(size)")
            XCTAssertEqual(digest, digest.lowercased(), "the API digest is lowercase hex")
        }
    }

    func testSHA256OfAMissingFileThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString)")
        XCTAssertThrowsError(try Installer.sha256(of: missing)) { _ in }
    }

    func testBundleIdentifierIsTheOneTheCaskInstalls() {
        XCTAssertEqual(Installer.bundleID, "com.github.sratabix.awsssh")
        XCTAssertEqual(Installer.bundleName, "Awsssh.app")
    }
}

extension InstallerTests {
    @MainActor func testInstallRefusesAReleaseWithNoVerifiableAsset() {
        let installer = Installer()
        let release = Release(version: "9.9.9", page: nil, asset: nil)
        installer.install(release)
        guard case .failed(let message) = installer.phase else {
            return XCTFail("expected a failure without an asset, got \(installer.phase)")
        }
        XCTAssertTrue(message.contains("brew upgrade --cask awsssh"), message)
    }

    @MainActor func testDismissClearsAFailureButNotABusyPhase() {
        let installer = Installer()
        installer.install(Release(version: "9.9.9", page: nil, asset: nil))
        XCTAssertFalse(installer.busy)
        installer.dismiss()
        XCTAssertEqual(installer.phase, .idle)
    }
}
