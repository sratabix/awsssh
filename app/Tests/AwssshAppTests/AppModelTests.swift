import XCTest

@testable import AwssshApp

final class AppModelTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("awsssh-model-\(UUID().uuidString)")
        Store.directoryOverride = tempDirectory
    }

    override func tearDown() {
        Store.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    @MainActor private func model() -> AppModel {
        AppModel(attached: false)
    }

    private func forward(_ id: Int, port: String = "5432", name: String = "") -> Forward {
        var f = Forward(id: id)
        f.name = name
        f.instance = "db"
        f.localPort = port
        f.remotePort = "5432"
        return f
    }

    @MainActor func testStartsEmptyWhenNothingIsSaved() {
        let m = model()
        XCTAssertTrue(m.forwards.isEmpty)
        XCTAssertNil(m.dataNotice)
        XCTAssertEqual(m.runningCount, 0)
    }

    @MainActor func testLoadsWhatWasSaved() {
        _ = Store.save([forward(1, name: "saved")], expecting: nil)
        XCTAssertEqual(model().forwards.map(\.name), ["saved"])
    }

    @MainActor func testSurfacesALoadNotice() {
        try? Data("not json".utf8).write(to: Store.fileURL)
        XCTAssertNotNil(model().dataNotice)
    }

    @MainActor func testBeginAddOffersTheNextFreeID() {
        _ = Store.save([forward(1), forward(7)], expecting: nil)
        let m = model()

        m.beginAdd()
        XCTAssertTrue(m.showingForm)
        XCTAssertEqual(m.editing?.id, 8)
        XCTAssertNil(m.formError)
    }

    @MainActor func testBeginAddOnAnEmptyListStartsAtOne() {
        let m = model()
        m.beginAdd()
        XCTAssertEqual(m.editing?.id, 1)
    }

    @MainActor func testBeginEditCarriesTheExistingForward() {
        _ = Store.save([forward(4, name: "pg")], expecting: nil)
        let m = model()

        m.beginEdit(m.forwards[0])
        XCTAssertTrue(m.showingForm)
        XCTAssertEqual(m.editing?.id, 4)
        XCTAssertEqual(m.editing?.name, "pg")
    }

    @MainActor func testBeginAddClearsAPendingDelete() {
        _ = Store.save([forward(1)], expecting: nil)
        let m = model()

        m.confirmDelete(m.forwards[0])
        m.beginAdd()
        XCTAssertNil(m.pendingDelete)
    }

    @MainActor func testBeginEditClearsAPendingDelete() {
        _ = Store.save([forward(1)], expecting: nil)
        let m = model()

        m.confirmDelete(m.forwards[0])
        m.beginEdit(m.forwards[0])
        XCTAssertNil(m.pendingDelete)
    }

    @MainActor func testSaveFormAddsAndPersists() {
        let m = model()
        m.beginAdd()
        m.saveForm(forward(1, name: "new"))

        XCTAssertEqual(m.forwards.map(\.name), ["new"])
        XCTAssertFalse(m.showingForm)
        XCTAssertNil(m.editing)
        XCTAssertEqual(Store.load().forwards.map(\.name), ["new"], "the save should have reached disk")
    }

    @MainActor func testSaveFormUpdatesInPlaceWithoutDuplicating() {
        let m = model()
        m.saveForm(forward(1, name: "first"))

        var edited = m.forwards[0]
        edited.name = "renamed"
        m.saveForm(edited)

        XCTAssertEqual(m.forwards.count, 1)
        XCTAssertEqual(m.forwards[0].name, "renamed")
    }

    @MainActor func testSaveFormRejectsAnInvalidForward() {
        let m = model()
        var broken = forward(1)
        broken.localPort = "not-a-port"

        m.saveForm(broken)

        XCTAssertNotNil(m.formError)
        XCTAssertTrue(m.forwards.isEmpty)
        XCTAssertTrue(Store.load().forwards.isEmpty, "an invalid forward must not be persisted")
    }

    @MainActor func testSaveFormKeepsTheFormOpenOnError() {
        let m = model()
        m.beginAdd()
        var broken = forward(1)
        broken.instance = ""

        m.saveForm(broken)
        XCTAssertTrue(m.showingForm, "the user needs the form to stay open to fix it")
    }

    @MainActor func testSaveFormRejectsADuplicateShortcut() {
        let m = model()
        var first = forward(1, port: "1")
        first.name = "first"
        first.hotKey = HotKey(keyCode: 11, carbonModifiers: 256)
        m.saveForm(first)

        var second = forward(2, port: "2")
        second.name = "second"
        second.hotKey = HotKey(keyCode: 11, carbonModifiers: 256)
        m.saveForm(second)

        XCTAssertEqual(m.forwards.count, 1, "the clashing forward must not be added")
        XCTAssertNotNil(m.formError)
        XCTAssertTrue(m.formError?.contains("first") == true, m.formError ?? "")
    }

    @MainActor func testSaveFormAllowsKeepingYourOwnShortcut() {
        let m = model()
        var f = forward(1)
        f.hotKey = HotKey(keyCode: 11, carbonModifiers: 256)
        m.saveForm(f)

        var edited = m.forwards[0]
        edited.name = "renamed"
        m.saveForm(edited)

        XCTAssertNil(m.formError)
        XCTAssertEqual(m.forwards[0].name, "renamed")
    }

    @MainActor func testCancelFormDiscardsTheDraft() {
        let m = model()
        m.beginAdd()
        m.cancelForm()

        XCTAssertFalse(m.showingForm)
        XCTAssertNil(m.editing)
        XCTAssertNil(m.formError)
        XCTAssertTrue(m.forwards.isEmpty)
    }

    @MainActor func testConfirmAndCancelDelete() {
        _ = Store.save([forward(1)], expecting: nil)
        let m = model()

        m.confirmDelete(m.forwards[0])
        XCTAssertEqual(m.pendingDelete?.id, 1)

        m.cancelDelete()
        XCTAssertNil(m.pendingDelete)
        XCTAssertEqual(m.forwards.count, 1, "cancelling must not delete anything")
    }

    @MainActor func testDeleteRemovesPersistsAndClearsState() {
        _ = Store.save([forward(1), forward(2, port: "5433")], expecting: nil)
        let m = model()
        m.handle(HelperMessage(event: "started", id: 1, detail: "localhost:5432"))

        m.delete(m.forwards[0])

        XCTAssertEqual(m.forwards.map(\.id), [2])
        XCTAssertNil(m.states[1])
        XCTAssertNil(m.pendingDelete)
        XCTAssertEqual(Store.load().forwards.map(\.id), [2])
    }

    @MainActor func testToggleRefusesAnInvalidForward() {
        let m = model()
        var broken = forward(1)
        broken.remotePort = "0"

        m.toggle(broken)

        XCTAssertEqual(m.state(for: broken).run, .error)
        XCTAssertFalse(m.state(for: broken).error.isEmpty)
    }

    @MainActor func testToggleRefusesALocalPortAlreadyInUse() {
        let m = model()
        m.saveForm(forward(1, port: "5432", name: "holder"))
        m.saveForm(forward(2, port: "5432", name: "clasher"))
        m.handle(HelperMessage(event: "started", id: 1, detail: "localhost:5432"))

        m.toggle(m.forwards[1])

        let state = m.state(for: m.forwards[1])
        XCTAssertEqual(state.run, .error)
        XCTAssertTrue(state.error.contains("5432"), state.error)
        XCTAssertTrue(state.error.contains("holder"), state.error)
    }

    @MainActor func testToggleAllowsTheSamePortWhenTheOtherIsStopped() {
        let m = model()
        m.saveForm(forward(1, port: "5432", name: "holder"))
        m.saveForm(forward(2, port: "5432", name: "second"))
        m.handle(HelperMessage(event: "exited", id: 1))

        m.toggle(m.forwards[1])
        XCTAssertEqual(m.state(for: m.forwards[1]).run, .starting)
    }

    @MainActor func testToggleMovesAStoppedForwardToStarting() {
        let m = model()
        m.saveForm(forward(1))

        m.toggle(m.forwards[0])

        XCTAssertEqual(m.state(for: m.forwards[0]).run, .starting)
        XCTAssertEqual(m.state(for: m.forwards[0]).error, "")
    }

    @MainActor func testToggleMovesARunningForwardToStopping() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "started", id: 1))

        m.toggle(m.forwards[0])
        XCTAssertEqual(m.state(for: m.forwards[0]).run, .stopping)
    }

    @MainActor func testToggleIsIgnoredWhileStopping() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "started", id: 1))
        m.toggle(m.forwards[0])
        XCTAssertEqual(m.state(for: m.forwards[0]).run, .stopping)

        m.toggle(m.forwards[0])
        XCTAssertEqual(m.state(for: m.forwards[0]).run, .stopping, "a second toggle should be a no-op")
    }

    @MainActor func testStartedMessageRecordsTheDetail() {
        let m = model()
        m.handle(HelperMessage(event: "started", id: 3, detail: "localhost:9999"))

        XCTAssertEqual(m.states[3]?.run, .running)
        XCTAssertEqual(m.states[3]?.detail, "localhost:9999")
        XCTAssertEqual(m.states[3]?.error, "")
    }

    @MainActor func testExitedWithAnErrorBecomesAnErrorState() {
        let m = model()
        m.handle(HelperMessage(event: "exited", id: 3, error: "not signed in"))

        XCTAssertEqual(m.states[3]?.run, .error)
        XCTAssertEqual(m.states[3]?.error, "not signed in")
    }

    @MainActor func testExitedWithoutAnErrorBecomesStopped() {
        let m = model()
        m.handle(HelperMessage(event: "started", id: 3, detail: "localhost:1"))
        m.handle(HelperMessage(event: "exited", id: 3))

        XCTAssertEqual(m.states[3]?.run, .stopped)
        XCTAssertEqual(m.states[3]?.detail, "")
    }

    @MainActor func testExitedWithAnEmptyErrorStringIsStillStopped() {
        let m = model()
        m.handle(HelperMessage(event: "exited", id: 3, error: ""))
        XCTAssertEqual(m.states[3]?.run, .stopped)
    }

    @MainActor func testProfilesMessageIsStored() {
        let m = model()
        m.handle(HelperMessage(event: "profiles", profiles: ["a", "b"]))
        XCTAssertEqual(m.profiles, ["a", "b"])

        m.handle(HelperMessage(event: "profiles"))
        XCTAssertEqual(m.profiles, [], "a nil list clears the menu rather than keeping stale entries")
    }

    @MainActor func testUnknownEventsAreIgnored() {
        let m = model()
        m.handle(HelperMessage(event: "somethingNew", id: 1))
        XCTAssertNil(m.states[1])
    }

    @MainActor func testMessagesWithoutAnIDAreIgnored() {
        let m = model()
        m.handle(HelperMessage(event: "started"))
        m.handle(HelperMessage(event: "exited"))
        XCTAssertTrue(m.states.isEmpty)
    }

    @MainActor func testRunningCountOnlyCountsRunning() {
        let m = model()
        m.handle(HelperMessage(event: "started", id: 1))
        m.handle(HelperMessage(event: "started", id: 2))
        m.handle(HelperMessage(event: "exited", id: 2))
        m.handle(HelperMessage(event: "exited", id: 3, error: "boom"))

        XCTAssertEqual(m.runningCount, 1)
    }

    @MainActor func testLiveForwardIgnoresTheForwardItself() {
        let m = model()
        m.saveForm(forward(1, port: "5432"))
        m.handle(HelperMessage(event: "started", id: 1))

        XCTAssertNil(m.liveForward(onLocalPort: "5432", excluding: 1))
        XCTAssertNotNil(m.liveForward(onLocalPort: "5432", excluding: 99))
    }

    @MainActor func testLiveForwardTreatsStartingAndStoppingAsBusy() {
        let m = model()
        m.saveForm(forward(1, port: "5432"))

        m.toggle(m.forwards[0])
        XCTAssertNotNil(m.liveForward(onLocalPort: "5432", excluding: 99), "starting counts as busy")

        m.handle(HelperMessage(event: "started", id: 1))
        m.toggle(m.forwards[0])
        XCTAssertNotNil(m.liveForward(onLocalPort: "5432", excluding: 99), "stopping counts as busy")
    }

    @MainActor func testLiveForwardIgnoresErroredForwards() {
        let m = model()
        m.saveForm(forward(1, port: "5432"))
        m.handle(HelperMessage(event: "exited", id: 1, error: "boom"))

        XCTAssertNil(m.liveForward(onLocalPort: "5432", excluding: 99))
    }

    @MainActor func testRefreshDoesNothingWhenTheFileIsUnchanged() {
        let m = model()
        m.saveForm(forward(1, name: "mine"))

        m.refreshIfChanged()
        XCTAssertEqual(m.forwards.map(\.name), ["mine"])
    }

    @MainActor func testRefreshPicksUpAnExternalChange() throws {
        let m = model()
        m.saveForm(forward(1, name: "mine"))

        let external =
            #"{"version":1,"forwards":[{"id":9,"instance":"ext","localPort":"1","name":"external","remotePort":"2"}]}"#
        try Data(external.utf8).write(to: Store.fileURL)

        m.refreshIfChanged()
        XCTAssertEqual(m.forwards.map(\.name), ["external"])
    }

    @MainActor func testRefreshIsSkippedWhileTheFormIsOpen() throws {
        let m = model()
        m.saveForm(forward(1, name: "mine"))
        m.beginAdd()

        let external = #"{"version":1,"forwards":[{"id":9,"instance":"ext","localPort":"1","remotePort":"2"}]}"#
        try Data(external.utf8).write(to: Store.fileURL)

        m.refreshIfChanged()
        XCTAssertEqual(m.forwards.map(\.name), ["mine"], "an open form must not be yanked away")
    }

    @MainActor func testRefreshIsSkippedWhileADeleteIsPending() throws {
        let m = model()
        m.saveForm(forward(1, name: "mine"))
        m.confirmDelete(m.forwards[0])

        let external = #"{"version":1,"forwards":[{"id":9,"instance":"ext","localPort":"1","remotePort":"2"}]}"#
        try Data(external.utf8).write(to: Store.fileURL)

        m.refreshIfChanged()
        XCTAssertEqual(m.forwards.map(\.name), ["mine"])
    }

    @MainActor func testRefreshRefusesToOrphanARunningForward() throws {
        let m = model()
        m.saveForm(forward(1, name: "mine"))
        m.handle(HelperMessage(event: "started", id: 1))

        let external = #"{"version":1,"forwards":[{"id":9,"instance":"ext","localPort":"1","remotePort":"2"}]}"#
        try Data(external.utf8).write(to: Store.fileURL)

        m.refreshIfChanged()

        XCTAssertEqual(m.forwards.map(\.name), ["mine"], "a running forward is tracked by id and must not vanish")
        XCTAssertNotNil(m.dataNotice)
    }

    @MainActor func testRefreshAfterExternalChangeKeepsAddingIDsUnique() throws {
        let m = model()
        m.saveForm(forward(1))

        let external = #"{"version":1,"forwards":[{"id":40,"instance":"ext","localPort":"1","remotePort":"2"}]}"#
        try Data(external.utf8).write(to: Store.fileURL)
        m.refreshIfChanged()

        m.beginAdd()
        XCTAssertEqual(m.editing?.id, 41, "the next id must clear the reloaded ones")
    }

    @MainActor func testSavingAfterAnExternalChangeKeepsABackup() throws {
        let m = model()
        m.saveForm(forward(1, name: "mine"))

        let external = #"{"version":1,"forwards":[{"id":9,"instance":"ext","localPort":"1","remotePort":"2"}]}"#
        try Data(external.utf8).write(to: Store.fileURL)

        m.saveForm(forward(2, port: "6000", name: "another"))

        let backup = tempDirectory.appendingPathComponent("forwards.conflict.backup.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    @MainActor func testDeletingSomethingThatIsGoneIsHarmless() {
        let m = model()
        m.delete(forward(99))
        XCTAssertTrue(m.forwards.isEmpty)
    }

    @MainActor func testStateForAnUnknownForwardIsStopped() {
        XCTAssertEqual(model().state(for: forward(123)).run, .stopped)
    }

    @MainActor func testStartedStampsTheUptimeClock() throws {
        let m = model()
        m.handle(HelperMessage(event: "started", id: 1, detail: "localhost:5432"))

        let state = try XCTUnwrap(m.states[1])
        let since = try XCTUnwrap(state.since)
        XCTAssertEqual(state.uptime(at: since.addingTimeInterval(65)), "1m 5s")
    }

    @MainActor func testStoppingClearsTheUptimeClock() {
        let m = model()
        m.handle(HelperMessage(event: "started", id: 1))
        m.handle(HelperMessage(event: "exited", id: 1))

        XCTAssertNil(m.states[1]?.since)
        XCTAssertNil(m.states[1]?.uptime(at: Date()))
    }

    @MainActor func testUptimeIsOnlyReportedWhileRunning() {
        var s = EntryState()
        s.since = Date()
        s.run = .reconnecting
        XCTAssertNil(s.uptime(at: Date().addingTimeInterval(30)))
    }

    @MainActor func testWakeMovesRunningForwardsToReconnecting() {
        let m = model()
        m.saveForm(forward(1, port: "5432", name: "live"))
        m.saveForm(forward(2, port: "5433", name: "idle"))
        m.handle(HelperMessage(event: "started", id: 1, detail: "localhost:5432"))

        m.reconnectLiveForwards(reason: .sleep)

        XCTAssertEqual(m.states[1]?.run, .reconnecting)
        XCTAssertNil(m.states[1]?.since, "the clock restarts with the tunnel")
        XCTAssertEqual(m.states[1]?.detail, "after sleep")
        XCTAssertNil(m.states[2]?.run, "a stopped forward must not be woken")
        XCTAssertEqual(m.runningCount, 0, "reconnecting is not running")
    }

    @MainActor func testReconnectRestartsOnTheExitItAskedFor() {
        let m = model()
        m.saveForm(forward(1, name: "live"))
        m.handle(HelperMessage(event: "started", id: 1))
        m.reconnectLiveForwards(reason: .sleep)

        m.handle(HelperMessage(event: "exited", id: 1))
        XCTAssertEqual(m.states[1]?.run, .reconnecting, "the exit is the handshake, not a stop")

        m.handle(HelperMessage(event: "started", id: 1, detail: "localhost:5432"))
        XCTAssertEqual(m.states[1]?.run, .running)
        XCTAssertNotNil(m.states[1]?.since)
    }

    @MainActor func testAFailedReconnectSurfacesAsAnErrorAndDoesNotLoop() {
        let m = model()
        m.saveForm(forward(1, name: "live"))
        m.handle(HelperMessage(event: "started", id: 1))
        m.reconnectLiveForwards(reason: .sleep)

        m.handle(HelperMessage(event: "exited", id: 1))
        m.handle(HelperMessage(event: "exited", id: 1, error: "not signed in"))

        XCTAssertEqual(m.states[1]?.run, .error)
        XCTAssertEqual(m.states[1]?.error, "not signed in")
    }

    @MainActor func testStoppingDuringAReconnectCancelsTheRestart() {
        let m = model()
        m.saveForm(forward(1, name: "live"))
        m.handle(HelperMessage(event: "started", id: 1))
        m.reconnectLiveForwards(reason: .sleep)

        m.toggle(m.forwards[0])
        XCTAssertEqual(m.states[1]?.run, .stopping)

        m.handle(HelperMessage(event: "exited", id: 1))
        XCTAssertEqual(m.states[1]?.run, .stopped, "the cancelled restart must not fire")
    }

    @MainActor func testReconnectingHoldsTheLocalPort() {
        let m = model()
        m.saveForm(forward(1, port: "5432"))
        m.handle(HelperMessage(event: "started", id: 1))
        m.reconnectLiveForwards(reason: .sleep)

        XCTAssertNotNil(
            m.liveForward(onLocalPort: "5432", excluding: 99),
            "the plugin still owns the port while it restarts")
    }

    @MainActor func testReconnectReasonReachesTheStatusLine() {
        let m = model()
        m.saveForm(forward(1, name: "live"))
        m.handle(HelperMessage(event: "started", id: 1))

        m.reconnectLiveForwards(reason: .network)
        XCTAssertEqual(m.states[1]?.detail, "after a network change")
    }

    @MainActor func testASecondReconnectWithinTheCooldownIsIgnored() {
        let m = model()
        m.saveForm(forward(1, name: "live"))
        m.handle(HelperMessage(event: "started", id: 1))

        let wake = Date()
        m.reconnectLiveForwards(reason: .sleep, now: wake)
        m.handle(HelperMessage(event: "exited", id: 1))
        m.handle(HelperMessage(event: "started", id: 1))

        m.reconnectLiveForwards(reason: .network, now: wake.addingTimeInterval(3))

        XCTAssertEqual(
            m.states[1]?.run, .running,
            "the path settling after a wake must not restart what the wake already restarted")
    }

    @MainActor func testAReconnectAfterTheCooldownIsAllowed() {
        let m = model()
        m.saveForm(forward(1, name: "live"))
        m.handle(HelperMessage(event: "started", id: 1))

        let first = Date()
        m.reconnectLiveForwards(reason: .sleep, now: first)
        m.handle(HelperMessage(event: "exited", id: 1))
        m.handle(HelperMessage(event: "started", id: 1))

        m.reconnectLiveForwards(
            reason: .network,
            now: first.addingTimeInterval(AppModel.reconnectCooldown + 1))

        XCTAssertEqual(m.states[1]?.run, .reconnecting)
    }

    @MainActor func testAReconnectWithNothingRunningDoesNotArmTheCooldown() {
        let m = model()
        m.saveForm(forward(1, name: "live"))

        let idle = Date()
        m.reconnectLiveForwards(reason: .network, now: idle)
        m.handle(HelperMessage(event: "started", id: 1))
        m.reconnectLiveForwards(reason: .network, now: idle.addingTimeInterval(1))

        XCTAssertEqual(
            m.states[1]?.run, .reconnecting,
            "a no-op reconnect must not block the next real one")
    }

    @MainActor func testNothingRunningNeedsNoAttention() {
        let m = model()
        m.saveForm(forward(1))
        XCTAssertFalse(m.needsAttention)
    }

    @MainActor func testAHealthyForwardNeedsNoAttention() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "started", id: 1))
        XCTAssertFalse(m.needsAttention, "running is the happy path")
    }

    @MainActor func testStartingAndStoppingNeedNoAttention() {
        let m = model()
        m.saveForm(forward(1))

        m.toggle(m.forwards[0])
        XCTAssertEqual(m.states[1]?.run, .starting)
        XCTAssertFalse(m.needsAttention, "the user asked for this one")

        m.handle(HelperMessage(event: "started", id: 1))
        m.toggle(m.forwards[0])
        XCTAssertEqual(m.states[1]?.run, .stopping)
        XCTAssertFalse(m.needsAttention, "the user asked for this one too")
    }

    @MainActor func testReconnectingNeedsAttention() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "started", id: 1))

        m.reconnectLiveForwards(reason: .network)
        XCTAssertTrue(m.needsAttention)
    }

    @MainActor func testAnErrorNeedsAttention() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "exited", id: 1, error: "not signed in"))
        XCTAssertTrue(m.needsAttention)
    }

    @MainActor func testAttentionClearsWhenTheReconnectSucceeds() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "started", id: 1))
        m.reconnectLiveForwards(reason: .sleep)
        XCTAssertTrue(m.needsAttention)

        m.handle(HelperMessage(event: "exited", id: 1))
        m.handle(HelperMessage(event: "started", id: 1))
        XCTAssertFalse(m.needsAttention, "the badge must not outlive the problem")
    }

    @MainActor func testAnOrphanedStateDoesNotStickTheBadgeOn() {
        let m = model()
        m.handle(HelperMessage(event: "exited", id: 77, error: "boom"))

        XCTAssertFalse(
            m.needsAttention,
            "a state with no forward behind it would badge the menubar forever")
    }

    @MainActor func testDeletingTheBrokenForwardClearsTheBadge() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "exited", id: 1, error: "boom"))
        XCTAssertTrue(m.needsAttention)

        m.delete(m.forwards[0])
        XCTAssertFalse(m.needsAttention)
    }

    @MainActor func testUptimeLabelBuckets() {
        XCTAssertEqual(EntryState.uptimeLabel(0), "0s")
        XCTAssertEqual(EntryState.uptimeLabel(-5), "0s")
        XCTAssertEqual(EntryState.uptimeLabel(9.7), "9s")
        XCTAssertEqual(EntryState.uptimeLabel(59), "59s")
        XCTAssertEqual(EntryState.uptimeLabel(60), "1m 0s")
        XCTAssertEqual(EntryState.uptimeLabel(3599), "59m 59s")
        XCTAssertEqual(EntryState.uptimeLabel(3600), "1h 0m")
        XCTAssertEqual(EntryState.uptimeLabel(7_500), "2h 5m")
    }

    @MainActor func testAStopTheUserAskedForNeverLandsInError() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "started", id: 1))

        m.toggle(m.forwards[0])
        m.handle(HelperMessage(event: "exited", id: 1, error: "context canceled"))

        XCTAssertEqual(m.states[1]?.run, .stopped, "the user asked for this teardown")
        XCTAssertEqual(m.states[1]?.error, "")
        XCTAssertFalse(m.needsAttention, "the badge must not outlive a deliberate stop")
    }

    @MainActor func testStoppingClearsAnErrorLeftBehindByAnEarlierRun() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "exited", id: 1, error: "not signed in"))
        m.toggle(m.forwards[0])
        m.handle(HelperMessage(event: "started", id: 1))
        m.toggle(m.forwards[0])
        m.handle(HelperMessage(event: "exited", id: 1))

        XCTAssertEqual(m.states[1]?.error, "", "a stale message would reappear on the next failure")
    }

    @MainActor func testDismissingAnErrorClearsTheBadge() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "exited", id: 1, error: "not signed in"))
        XCTAssertTrue(m.needsAttention)

        m.dismissError(m.forwards[0])

        XCTAssertEqual(m.states[1]?.run, .stopped)
        XCTAssertEqual(m.states[1]?.error, "")
        XCTAssertFalse(m.needsAttention)
    }

    @MainActor func testDismissOnlyTouchesAnErroredForward() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "started", id: 1))

        m.dismissError(m.forwards[0])
        XCTAssertEqual(m.states[1]?.run, .running, "dismiss is not a stop button")
    }

    @MainActor func testOnlyOneErrorIsExpandedAtATime() {
        let m = model()
        m.toggleErrorDetail(1)
        XCTAssertEqual(m.expandedError, 1)

        m.toggleErrorDetail(2)
        XCTAssertEqual(m.expandedError, 2, "a second row replaces the first")

        m.toggleErrorDetail(2)
        XCTAssertNil(m.expandedError, "the same row collapses")
    }

    @MainActor func testLeavingTheErrorStateCollapsesTheDetail() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "exited", id: 1, error: "not signed in"))
        m.toggleErrorDetail(1)

        m.toggle(m.forwards[0])

        XCTAssertEqual(m.states[1]?.run, .starting)
        XCTAssertNil(m.expandedError, "a panel about an error that is gone")
    }

    @MainActor func testDeletingAForwardCollapsesItsDetail() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "exited", id: 1, error: "boom"))
        m.toggleErrorDetail(1)

        m.delete(m.forwards[0])
        XCTAssertNil(m.expandedError)
    }
}
