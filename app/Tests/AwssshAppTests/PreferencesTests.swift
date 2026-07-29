import XCTest

@testable import AwssshApp

final class PreferencesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "awsssh-prefs-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        Preferences.store = defaults
    }

    override func tearDown() {
        Preferences.store = .standard
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testTheSSORowIsOnUntilItIsTurnedOff() {
        XCTAssertTrue(Preferences.showSSO, "a fresh install should see the sign-in it can use")

        Preferences.showSSO = false
        XCTAssertFalse(Preferences.showSSO)

        Preferences.showSSO = true
        XCTAssertTrue(Preferences.showSSO)
    }

    func testTheChoiceOutlivesTheObject() {
        Preferences.showSSO = false
        XCTAssertFalse(
            UserDefaults(suiteName: suite)?.bool(forKey: Preferences.showSSOKey) ?? true,
            "the toggle has to survive a relaunch")
    }

    @MainActor func testTheModelWritesThroughToPreferences() {
        Store.directoryOverride = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("awsssh-prefs-model-\(UUID().uuidString)")
        defer { Store.directoryOverride = nil }

        let m = AppModel(attached: false)
        XCTAssertTrue(m.showSSO)

        m.showSSO = false
        XCTAssertFalse(Preferences.showSSO, "the window is closed by the time this matters")
    }

    @MainActor func testTheModelReadsPreferencesAtLaunch() {
        Preferences.showSSO = false
        Store.directoryOverride = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("awsssh-prefs-model-\(UUID().uuidString)")
        defer { Store.directoryOverride = nil }

        XCTAssertFalse(AppModel(attached: false).showSSO)
    }

    @MainActor func testSettingsOpenAndClose() {
        Store.directoryOverride = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("awsssh-prefs-model-\(UUID().uuidString)")
        defer { Store.directoryOverride = nil }

        let m = AppModel(attached: false)
        XCTAssertFalse(m.showingSettings)

        m.openSettings()
        XCTAssertTrue(m.showingSettings)

        m.closeSettings()
        XCTAssertFalse(m.showingSettings, "the close box routes back through this")
    }
}
