import XCTest

@testable import AwssshApp

final class DNSCheckTests: XCTestCase {
    @MainActor func testNothingResolvesUntilItHasBeenConfirmed() {
        let dns = DNSCheck(settle: .seconds(60))
        XCTAssertFalse(
            dns.resolves("portal.example.com"),
            "a launch with no probe yet must not read as working DNS")
    }

    @MainActor func testAConfirmedHostResolves() {
        let dns = DNSCheck(settle: .seconds(60))
        dns.adopt("portal.example.com")

        XCTAssertTrue(dns.resolves("portal.example.com"))
        XCTAssertFalse(
            dns.resolves("other.example.com"),
            "a different host was never looked up")
    }

    @MainActor func testInvalidateForgetsAConfirmedHost() {
        let dns = DNSCheck(settle: .seconds(60))
        dns.adopt("portal.example.com")

        dns.invalidate()

        XCTAssertFalse(
            dns.resolves("portal.example.com"),
            "the network changed, so the old answer proves nothing")
    }

    @MainActor func testAdoptingNotifies() {
        let dns = DNSCheck(settle: .seconds(60))
        var fired = 0
        dns.onResolve = { fired += 1 }

        dns.adopt("portal.example.com")

        XCTAssertEqual(fired, 1, "the sign-in must not wait for the next poll")
    }

    @MainActor func testOneLookupIsNotEnough() {
        let dns = DNSCheck(settle: .seconds(60))
        dns.lookup = { _ in true }

        dns.confirm("portal.example.com")

        XCTAssertFalse(
            dns.resolves("portal.example.com"),
            "confirming waits for a second pass, so a network coming up is not believed at once")
    }

    @MainActor func testAnEmptyHostIsNeverProbed() {
        let dns = DNSCheck(settle: .seconds(60))
        dns.lookup = { _ in
            XCTFail("nothing to resolve")
            return true
        }

        dns.confirm("")

        XCTAssertFalse(dns.resolves(""))
    }

    @MainActor func testAnOverrideWinsOverEveryProbe() {
        let dns = DNSCheck(settle: .seconds(60))
        dns.resolvedOverride = true
        XCTAssertTrue(dns.resolves("anything.example.com"))

        dns.resolvedOverride = false
        dns.adopt("portal.example.com")
        XCTAssertFalse(dns.resolves("portal.example.com"), "the override is the test seam")
    }
}
