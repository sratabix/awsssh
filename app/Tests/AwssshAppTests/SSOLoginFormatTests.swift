import XCTest

@testable import AwssshApp

final class SSOLoginFormatTests: XCTestCase {
    func testRemainingBuckets() {
        XCTAssertEqual(SSOLogin.remaining(0), "under a minute")
        XCTAssertEqual(SSOLogin.remaining(1), "under a minute")
        XCTAssertEqual(SSOLogin.remaining(59), "under a minute")
        XCTAssertEqual(SSOLogin.remaining(60), "1m")
        XCTAssertEqual(SSOLogin.remaining(119), "1m")
        XCTAssertEqual(SSOLogin.remaining(3599), "59m")
        XCTAssertEqual(SSOLogin.remaining(3600), "1h 0m")
        XCTAssertEqual(SSOLogin.remaining(3660), "1h 1m")
        XCTAssertEqual(SSOLogin.remaining(7_500), "2h 5m")
        XCTAssertEqual(SSOLogin.remaining(86_400), "24h 0m")
    }

    func testRemainingRoundsDownRatherThanUp() {
        XCTAssertEqual(SSOLogin.remaining(59.9), "under a minute", "59.9s must not read as a minute")
        XCTAssertEqual(SSOLogin.remaining(60.9), "1m")
        XCTAssertEqual(SSOLogin.remaining(3599.9), "59m", "this must not jump to an hour early")
    }

    func testRemainingOfANegativeIntervalDoesNotProduceNonsense() {
        for seconds in [-1.0, -60.0, -100_000.0] {
            let label = SSOLogin.remaining(seconds)
            XCTAssertFalse(label.contains("-"), "\(seconds) produced \(label)")
        }
    }

    func testLoginCheckDefaultsToUnknownForAnythingUnexpected() {
        XCTAssertEqual(LoginCheck(nil), .unknown)
        XCTAssertEqual(LoginCheck(""), .unknown)
        XCTAssertEqual(LoginCheck("nonsense"), .unknown)
        XCTAssertEqual(LoginCheck("VALID"), .unknown, "the wire values are lowercase")
        XCTAssertEqual(LoginCheck(" valid"), .unknown)
    }

    func testLoginCheckReadsTheThreeWireValues() {
        XCTAssertEqual(LoginCheck("valid"), .valid)
        XCTAssertEqual(LoginCheck("expired"), .expired)
        XCTAssertEqual(LoginCheck("unknown"), .unknown)
    }

    func testCoversDescribesTheProfileCount() {
        XCTAssertEqual(SSOLogin(label: "a", profiles: []).covers, "")
        XCTAssertEqual(SSOLogin(label: "a", profiles: ["only"]).covers, "only")
        XCTAssertEqual(SSOLogin(label: "a", profiles: ["one", "two"]).covers, "2 profiles")
        XCTAssertEqual(
            SSOLogin(label: "a", profiles: Array(repeating: "p", count: 20)).covers, "20 profiles")
    }

    func testStatusOfAnExpiredCheckIgnoresAHopefulCache() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let login = SSOLogin(
            label: "company", profiles: ["dev"], expires: now.addingTimeInterval(3600),
            refreshable: true)
        XCTAssertEqual(
            login.status(at: now, check: .expired), "sign-in needed",
            "asking AWS beats anything the cache implied")
    }

    func testStatusOfARefreshableTokenNeverShowsACountdown() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in [-7200.0, -1.0, 1.0, 7200.0] {
            let login = SSOLogin(
                label: "company", expires: now.addingTimeInterval(offset), refreshable: true)
            XCTAssertEqual(
                login.status(at: now), "signed in",
                "a token that can renew must not count down to zero")
        }
    }

    func testStatusCountsDownOnlyWhenTheExpiryIsTheRealCutoff() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let login = SSOLogin(
            label: "company", expires: now.addingTimeInterval(7_500), refreshable: false)
        XCTAssertEqual(login.status(at: now), "signed in · 2h 5m left")
    }

    func testStatusAtTheExactExpiryIsSignedOut() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let login = SSOLogin(label: "company", expires: now, refreshable: false)
        XCTAssertEqual(login.status(at: now), "signed out")
        XCTAssertFalse(login.signedIn(at: now))
    }

    func testSignedInPrefersTheCheckOverTheCacheInBothDirections() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = SSOLogin(label: "a", expires: now.addingTimeInterval(-3600))
        let fresh = SSOLogin(label: "a", expires: now.addingTimeInterval(3600))

        XCTAssertTrue(stale.signedIn(at: now, check: .valid), "a passing check revives a stale cache")
        XCTAssertFalse(fresh.signedIn(at: now, check: .expired), "a failing check overrides a fresh cache")
        XCTAssertFalse(stale.signedIn(at: now, check: .unknown))
        XCTAssertTrue(fresh.signedIn(at: now, check: .unknown))
    }

    func testParseAcceptsTheLayoutsTheHelperSends() {
        XCTAssertNotNil(SSOLogin.parse("2026-07-31T12:00:00Z"))
        XCTAssertNotNil(SSOLogin.parse("2026-07-31T12:00:00.123Z"))
        XCTAssertNotNil(SSOLogin.parse("2026-07-31T14:00:00+02:00"))
    }

    func testParseRejectsGarbage() {
        for value in ["", "not a date", "1700000000", "2026-07-31", "31/07/2026"] {
            XCTAssertNil(SSOLogin.parse(value), "\(value.debugDescription) must not parse")
        }
    }

    func testParseNormalisesAnOffsetToTheSameInstant() {
        let withOffset = SSOLogin.parse("2026-07-31T14:00:00+02:00")
        let asUTC = SSOLogin.parse("2026-07-31T12:00:00Z")
        XCTAssertEqual(withOffset, asUTC, "the same instant written two ways must compare equal")
    }

    func testTheWireInitDefaultsEverythingThatIsAbsent() {
        let login = SSOLogin(HelperLogin(label: "company"))
        XCTAssertEqual(login.label, "company")
        XCTAssertEqual(login.profiles, [], "a missing profile list is empty, not nil")
        XCTAssertNil(login.expires)
        XCTAssertFalse(login.refreshable)
    }
}
