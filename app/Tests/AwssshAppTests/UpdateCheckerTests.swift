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
}
