import XCTest
@testable import AwssshApp

final class UpdateCheckerTests: XCTestCase {
    func testParseTagStripsLeadingV() {
        let data = Data(#"{"tag_name":"v0.4.2","name":"0.4.2"}"#.utf8)
        XCTAssertEqual(UpdateChecker.parseTag(data), "0.4.2")
    }

    func testParseTagRejectsGarbage() {
        XCTAssertNil(UpdateChecker.parseTag(Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.parseTag(Data(#"{"message":"Not Found"}"#.utf8)))
    }

    func testIsNewerComparesNumerically() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.10.0", current: "0.9.0"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.0", current: "0.99.99"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.2.1", current: "0.2.0"))
    }

    func testIsNewerRejectsSameOrOlder() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.2.0", current: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.1.9", current: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.9.0", current: "0.10.0"))
    }

    func testDevBuildIsNotOutrankedBySameRelease() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.1.0", current: "0.1.0-dev"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.2.0", current: "0.1.0-dev"))
    }

    func testShorterVersionsPadWithZero() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "0.2", current: "0.1.9"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.2", current: "0.2.0"))
    }
}

extension UpdateCheckerTests {
    func testParseTagAcceptsATagWithoutV() {
        XCTAssertEqual(UpdateChecker.parseTag(Data(#"{"tag_name":"1.2.3"}"#.utf8)), "1.2.3")
    }

    func testParseTagHandlesPrereleaseSuffixes() {
        XCTAssertEqual(UpdateChecker.parseTag(Data(#"{"tag_name":"v2.0.0-beta.1"}"#.utf8)), "2.0.0-beta.1")
    }

    func testParseTagRejectsAWrongType() {
        XCTAssertNil(UpdateChecker.parseTag(Data(#"{"tag_name":42}"#.utf8)))
        XCTAssertNil(UpdateChecker.parseTag(Data("[]".utf8)))
        XCTAssertNil(UpdateChecker.parseTag(Data("".utf8)))
    }

    func testParseTagIgnoresOtherFields() {
        let data = Data(#"{"name":"Release","draft":false,"tag_name":"v0.9.1","assets":[]}"#.utf8)
        XCTAssertEqual(UpdateChecker.parseTag(data), "0.9.1")
    }

    func testParseTagOfALoneV() {
        XCTAssertEqual(UpdateChecker.parseTag(Data(#"{"tag_name":"v"}"#.utf8)), "")
    }

    func testIsNewerAcrossMajorMinorPatch() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "2.0.0", current: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.10.0", current: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.9.10", current: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.9.9", current: "2.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.9.9", current: "1.10.0"))
    }

    func testIsNewerWithEmptyStrings() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "", current: ""))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "", current: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.0", current: ""))
    }

    func testIsNewerIgnoresNonNumericNoise() {
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.0.0", current: "1.0.0-rc1"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.1", current: "1.0.0-rc1"))
    }

    func testIsNewerWithLongerVersions() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.0.1", current: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.0.0", current: "1.0.0.1"))
    }

    func testDisplayVersionIsPrefixed() {
        XCTAssertTrue(AppInfo.displayVersion.hasPrefix("v"))
        XCTAssertEqual(AppInfo.displayVersion, "v" + AppInfo.version)
    }

    func testVersionIsNeverEmpty() {
        XCTAssertFalse(AppInfo.version.isEmpty)
    }

    func testUserAgentCarriesOnlyTheAppVersion() {
        XCTAssertEqual(AppInfo.userAgent, "Awsssh/" + AppInfo.version)
    }
}

extension UpdateCheckerTests {
    private func releaseJSON(
        tag: String = "v0.4.2",
        assetName: String = "Awsssh-0.4.2.zip",
        digest: String? = "sha256:\(String(repeating: "a", count: 64))",
        url: String = "https://github.com/sratabix/awsssh/releases/download/v0.4.2/Awsssh-0.4.2.zip",
        prerelease: Bool = false
    ) -> Data {
        let digestField = digest.map { #""digest":"\#($0)","# } ?? ""
        return Data(
            """
            {"tag_name":"\(tag)",
             "prerelease":\(prerelease),
             "html_url":"https://github.com/sratabix/awsssh/releases/tag/\(tag)",
             "assets":[{"name":"\(assetName)",\(digestField)"browser_download_url":"\(url)"}]}
            """.utf8
        )
    }

    func testParseReleaseReadsVersionPageAndAsset() {
        let release = UpdateChecker.parseRelease(releaseJSON())
        XCTAssertEqual(release?.version, "0.4.2")
        XCTAssertEqual(release?.page?.absoluteString, "https://github.com/sratabix/awsssh/releases/tag/v0.4.2")
        XCTAssertEqual(release?.asset?.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(
            release?.asset?.url.absoluteString,
            "https://github.com/sratabix/awsssh/releases/download/v0.4.2/Awsssh-0.4.2.zip"
        )
    }

    func testParseReleaseDropsAPrerelease() {
        XCTAssertNil(UpdateChecker.parseRelease(releaseJSON(prerelease: true)))
    }

    func testParseReleaseKeepsTheVersionButDropsAnUnusableAsset() {
        let noDigest = UpdateChecker.parseRelease(releaseJSON(digest: nil))
        XCTAssertEqual(noDigest?.version, "0.4.2")
        XCTAssertNil(noDigest?.asset)

        XCTAssertNil(UpdateChecker.parseRelease(releaseJSON(digest: "md5:abc"))?.asset)
        XCTAssertNil(UpdateChecker.parseRelease(releaseJSON(digest: "sha256:abc"))?.asset)
        XCTAssertNil(UpdateChecker.parseRelease(releaseJSON(assetName: "Awsssh-9.9.9.zip"))?.asset)
        XCTAssertNil(UpdateChecker.parseRelease(releaseJSON(assetName: "Awsssh.zip"))?.asset)
    }

    func testParseReleaseRejectsAnAssetOffGitHub() {
        let release = UpdateChecker.parseRelease(releaseJSON(url: "https://evil.example/Awsssh-0.4.2.zip"))
        XCTAssertEqual(release?.version, "0.4.2")
        XCTAssertNil(release?.asset)
    }

    func testParseReleaseRejectsAFullwidthDigestThatUIntWouldRefuse() {
        let wide = "sha256:" + String(repeating: "ａ", count: 64)
        XCTAssertNil(UpdateChecker.parseRelease(releaseJSON(digest: wide))?.asset)
    }

    func testParseReleaseAcceptsAnUppercaseDigest() {
        let digest = "sha256:" + String(repeating: "AB", count: 32)
        XCTAssertEqual(
            UpdateChecker.parseRelease(releaseJSON(digest: digest))?.asset?.sha256,
            String(repeating: "ab", count: 32)
        )
    }

    @MainActor func testAvailableIsNilUntilAReleaseIsNewerThanTheRunningBuild() {
        let checker = UpdateChecker()
        XCTAssertNil(checker.available)

        checker.adopt(Release(version: AppInfo.version, page: nil, asset: nil))
        XCTAssertNil(checker.available)

        checker.adopt(Release(version: "999.0.0", page: nil, asset: nil))
        XCTAssertEqual(checker.available?.version, "999.0.0")
    }
}
