import XCTest

@testable import AwssshApp

final class SSOLoginTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func login(in seconds: TimeInterval?, profiles: [String] = ["a", "b"]) -> SSOLogin {
        SSOLogin(
            label: "company",
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
            HelperLogin(label: "company", profiles: ["a"], expires: "2030-01-02T03:04:05Z"))

        XCTAssertEqual(decoded.label, "company")
        XCTAssertEqual(decoded.profiles, ["a"])
        XCTAssertEqual(decoded.expires?.timeIntervalSince1970, 1_893_553_445)
    }

    func testAMissingExpiryDecodesToNil() {
        let decoded = SSOLogin(HelperLogin(label: "company", profiles: nil, expires: nil))
        XCTAssertNil(decoded.expires)
        XCTAssertEqual(decoded.profiles, [])
    }

    func testAnUnparseableExpiryIsTreatedAsSignedOut() {
        let decoded = SSOLogin(HelperLogin(label: "company", profiles: [], expires: "whenever"))
        XCTAssertNil(decoded.expires)
        XCTAssertFalse(decoded.signedIn(at: now))
    }

    func testFractionalSecondsAreAccepted() {
        XCTAssertNotNil(SSOLogin.parse("2030-01-02T03:04:05.123Z"))
    }

    func testTheLabelIsTheIdentity() {
        XCTAssertEqual(login(in: 60).id, "company")
    }

    func testAnExpiryIsReadFromTheHelpersOwnFormat() {
        let emitted = "2026-07-29T09:56:19Z"
        let decoded = SSOLogin(HelperLogin(label: "company", profiles: [], expires: emitted))
        let justBefore = Date(timeIntervalSince1970: 1_785_318_979 - 22 * 60)

        XCTAssertNotNil(decoded.expires, "this is exactly what the Go side writes")
        XCTAssertEqual(decoded.status(at: justBefore), "signed in · 22m left")
    }

    func testARenewableTokenShowsNoCountdown() {
        let renewable = SSOLogin(
            label: "company", profiles: ["a"], expires: now.addingTimeInterval(-60), refreshable: true)

        XCTAssertTrue(
            renewable.signedIn(at: now),
            "the SDK renews this silently — connecting works long after expiresAt")
        XCTAssertEqual(
            renewable.status(at: now), "signed in",
            "counting down to the access token expiry would be a lie")
    }

    func testARenewableTokenThatIsStillFreshAlsoShowsNoCountdown() {
        let renewable = SSOLogin(
            label: "company", expires: now.addingTimeInterval(3600), refreshable: true)
        XCTAssertEqual(renewable.status(at: now), "signed in")
    }

    func testTheWireCarriesRefreshability() {
        let decoded = SSOLogin(
            HelperLogin(label: "s", profiles: [], expires: nil, refreshable: true))
        XCTAssertTrue(decoded.refreshable)
        XCTAssertTrue(decoded.signedIn(at: now))

        let older = SSOLogin(HelperLogin(label: "s", profiles: [], expires: nil))
        XCTAssertFalse(older.refreshable, "a helper that does not send the field is not refreshable")
    }

    func testAFailedCheckOverridesAHopefulCache() {
        let renewable = SSOLogin(
            label: "company", expires: now.addingTimeInterval(3600), refreshable: true)

        XCTAssertEqual(
            renewable.status(at: now, check: .expired), "sign-in needed",
            "the refresh token dies with the Identity Center session, which the cache never records")
        XCTAssertFalse(renewable.signedIn(at: now, check: .expired))
    }

    func testAPassedCheckOverridesAnExpiredCache() {
        let stale = SSOLogin(label: "company", expires: now.addingTimeInterval(-9999))

        XCTAssertTrue(stale.signedIn(at: now, check: .valid))
        XCTAssertEqual(stale.status(at: now, check: .valid), "signed in")
    }

    func testNoCachedTokenAtAllBeatsAPassedCheck() {
        let gone = SSOLogin(label: "company")

        XCTAssertFalse(
            gone.signedIn(at: now, check: .valid),
            "an expired token can be revived by a passing check, a missing one cannot")
        XCTAssertEqual(gone.status(at: now, check: .valid), "signed out")
    }

    func testAnUnknownCheckFallsBackToTheCache() {
        let renewable = SSOLogin(label: "company", refreshable: true)
        XCTAssertEqual(renewable.status(at: now, check: .unknown), "signed in")

        let dead = SSOLogin(label: "company", expires: now.addingTimeInterval(-1))
        XCTAssertEqual(dead.status(at: now, check: .unknown), "signed out")
    }

    func testTheCheckStateDecodesFromTheWire() {
        XCTAssertEqual(LoginCheck("valid"), .valid)
        XCTAssertEqual(LoginCheck("expired"), .expired)
        XCTAssertEqual(LoginCheck("unknown"), .unknown)
        XCTAssertEqual(LoginCheck(nil), .unknown)
        XCTAssertEqual(LoginCheck("something new"), .unknown, "a newer helper must not crash us")
    }

    func testTheCountdownFallsAsTimePasses() {
        let one = login(in: 3600)
        XCTAssertEqual(one.status(at: now), "signed in · 1h 0m left")
        XCTAssertEqual(one.status(at: now.addingTimeInterval(1800)), "signed in · 30m left")
        XCTAssertEqual(
            one.status(at: now.addingTimeInterval(3601)), "signed out",
            "the row must flip on its own once the token lapses")
    }
}
