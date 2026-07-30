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
