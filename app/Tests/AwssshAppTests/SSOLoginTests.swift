import XCTest

@testable import AwssshApp

final class SSOLoginTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func login(in seconds: TimeInterval?, profiles: [String] = ["a", "b"]) -> SSOLogin {
        SSOLogin(
            label: "sacha",
            profiles: profiles,
            expires: seconds.map { now.addingTimeInterval($0) })
    }

    func testAFutureExpiryIsSignedIn() {
        XCTAssertTrue(login(in: 60).signedIn(at: now))
        XCTAssertFalse(login(in: -60).signedIn(at: now))
        XCTAssertFalse(login(in: nil).signedIn(at: now), "no cached token means signed out")
    }

    func testStatusCountsDownToExpiry() {
        XCTAssertEqual(login(in: 3600 * 7 + 60 * 30).status(at: now), "signed in · 7h 30m left")
        XCTAssertEqual(login(in: 60 * 42).status(at: now), "signed in · 42m left")
        XCTAssertEqual(login(in: 5).status(at: now), "signed in · under a minute left")
    }

    func testAnExpiredTokenReadsAsSignedOut() {
        XCTAssertEqual(login(in: -1).status(at: now), "signed out")
        XCTAssertEqual(login(in: nil).status(at: now), "signed out")
    }

    func testCoversNamesOneProfileAndCountsTheRest() {
        XCTAssertEqual(login(in: 60, profiles: []).covers, "")
        XCTAssertEqual(login(in: 60, profiles: ["only"]).covers, "only")
        XCTAssertEqual(login(in: 60, profiles: ["a", "b", "c"]).covers, "3 profiles")
    }

    func testTheWireFormatDecodes() {
        let decoded = SSOLogin(
            HelperLogin(label: "sacha", profiles: ["a"], expires: "2030-01-02T03:04:05Z"))

        XCTAssertEqual(decoded.label, "sacha")
        XCTAssertEqual(decoded.profiles, ["a"])
        XCTAssertEqual(decoded.expires?.timeIntervalSince1970, 1_893_553_445)
    }

    func testAMissingExpiryDecodesToNil() {
        let decoded = SSOLogin(HelperLogin(label: "sacha", profiles: nil, expires: nil))
        XCTAssertNil(decoded.expires)
        XCTAssertEqual(decoded.profiles, [])
    }

    func testAnUnparseableExpiryIsTreatedAsSignedOut() {
        let decoded = SSOLogin(HelperLogin(label: "sacha", profiles: [], expires: "whenever"))
        XCTAssertNil(decoded.expires)
        XCTAssertFalse(decoded.signedIn(at: now))
    }

    func testFractionalSecondsAreAccepted() {
        XCTAssertNotNil(SSOLogin.parse("2030-01-02T03:04:05.123Z"))
    }

    func testTheLabelIsTheIdentity() {
        XCTAssertEqual(login(in: 60).id, "sacha")
    }
}
