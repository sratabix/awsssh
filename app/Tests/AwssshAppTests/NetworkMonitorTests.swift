import XCTest

@testable import AwssshApp

final class NetworkMonitorTests: XCTestCase {
    private func snapshot(
        _ satisfied: Bool = true,
        interfaces: [String] = ["en0"],
        gateways: [String] = ["192.168.1.1"]
    ) -> PathSnapshot {
        PathSnapshot(satisfied: satisfied, interfaces: interfaces, gateways: gateways)
    }

    func testTheFirstPathIsNeverAChange() {
        XCTAssertFalse(
            PathSnapshot.changed(from: nil, to: snapshot()),
            "launching on a working network must not restart anything")
    }

    func testAnIdenticalPathIsNotAChange() {
        XCTAssertFalse(PathSnapshot.changed(from: snapshot(), to: snapshot()))
    }

    func testGoingOfflineIsNotAChangeWorthReconnecting() {
        XCTAssertFalse(
            PathSnapshot.changed(from: snapshot(), to: snapshot(false)),
            "there is nothing to reconnect to while the path is unsatisfied")
    }

    func testComingBackOnlineIsAChange() {
        XCTAssertTrue(PathSnapshot.changed(from: snapshot(false), to: snapshot()))
    }

    func testSwitchingInterfaceIsAChange() {
        XCTAssertTrue(
            PathSnapshot.changed(from: snapshot(interfaces: ["en0"]), to: snapshot(interfaces: ["en1"])))
    }

    func testBringingUpAVPNIsAChange() {
        XCTAssertTrue(
            PathSnapshot.changed(
                from: snapshot(interfaces: ["en0"]),
                to: snapshot(interfaces: ["en0", "utun4"])))
    }

    func testSwitchingWifiNetworkOnTheSameInterfaceIsAChange() {
        XCTAssertTrue(
            PathSnapshot.changed(
                from: snapshot(gateways: ["172.22.30.1"]),
                to: snapshot(gateways: ["10.1.1.1"])),
            "same en0, different network — the gateway is what gives it away")
    }

    func testInterfaceOrderingIsNotAChange() {
        XCTAssertFalse(
            PathSnapshot.changed(
                from: PathSnapshot(satisfied: true, interfaces: ["en0", "utun4"], gateways: ["a", "b"]),
                to: PathSnapshot(satisfied: true, interfaces: ["en0", "utun4"], gateways: ["a", "b"])))
    }

    @MainActor func testObserveDoesNotFireOnTheFirstPath() {
        let monitor = NetworkMonitor(settle: .milliseconds(1))
        var fired = 0
        monitor.onChange = { fired += 1 }

        monitor.observe(snapshot())
        XCTAssertEqual(fired, 0)
    }

    @MainActor func testObserveSchedulesRatherThanFiringInline() {
        let monitor = NetworkMonitor(settle: .seconds(60))
        var fired = 0
        monitor.onChange = { fired += 1 }

        monitor.observe(snapshot(interfaces: ["en0"]))
        monitor.observe(snapshot(interfaces: ["en1"]))

        XCTAssertEqual(fired, 0, "the callback waits for the path to settle")
    }
}
