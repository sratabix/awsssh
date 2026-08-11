import AppKit
import Carbon.HIToolbox
import XCTest

@testable import AwssshApp

final class AppModelTests: XCTestCase {
    private var tempDirectory: URL!
    private var suite: String!

    override func setUp() {
        super.setUp()
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("awsssh-model-\(UUID().uuidString)")
        Store.directoryOverride = tempDirectory
        suite = "awsssh-model-\(UUID().uuidString)"
        Preferences.store = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        Store.directoryOverride = nil
        Preferences.store.removePersistentDomain(forName: suite)
        Preferences.store = .standard
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

    @MainActor func testSaveFormNormalisesTheColor() {
        let m = model()
        var typed = forward(1)
        typed.color = " f00 "
        m.saveForm(typed)

        XCTAssertEqual(m.forwards[0].color, "#FF0000", "what the user typed is not what is stored")
        XCTAssertEqual(Store.load().forwards[0].color, "#FF0000")
    }

    @MainActor func testSaveFormDropsAColorItCannotRead() {
        let m = model()
        var typed = forward(1)
        typed.color = "#zz"
        m.saveForm(typed)

        XCTAssertEqual(m.forwards.count, 1, "a bad color must not block the save")
        XCTAssertEqual(m.forwards[0].color, "")
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

    @MainActor func testStartAllStartsEverythingStopped() {
        let m = model()
        m.saveForm(forward(1, port: "5432"))
        m.saveForm(forward(2, port: "5433"))

        XCTAssertFalse(m.anyLive(in: m.forwards))
        m.toggleAll(m.forwards)

        XCTAssertEqual(m.state(for: m.forwards[0]).run, .starting)
        XCTAssertEqual(m.state(for: m.forwards[1]).run, .starting)
        XCTAssertTrue(m.anyLive(in: m.forwards), "the button has to flip to Stop all straight away")
    }

    @MainActor func testStopAllStopsEverythingLive() {
        let m = model()
        m.saveForm(forward(1, port: "5432"))
        m.saveForm(forward(2, port: "5433"))
        m.handle(HelperMessage(event: "started", id: 1))
        m.handle(HelperMessage(event: "started", id: 2))

        m.toggleAll(m.forwards)

        XCTAssertEqual(m.state(for: m.forwards[0]).run, .stopping)
        XCTAssertEqual(m.state(for: m.forwards[1]).run, .stopping)
    }

    @MainActor func testStartAllSkipsASharedLocalPortRatherThanErroring() {
        let m = model()
        m.saveForm(forward(1, port: "5432", name: "first"))
        m.saveForm(forward(2, port: "5432", name: "second"))

        m.startAll(m.forwards)

        XCTAssertEqual(m.state(for: m.forwards[0]).run, .starting)
        XCTAssertEqual(
            m.state(for: m.forwards[1]).run, .stopped,
            "two forwards on one port is a supported setup, not an error to shout about")
        XCTAssertTrue(m.state(for: m.forwards[1]).error.isEmpty)
    }

    @MainActor func testStartAllSkipsAnInvalidForward() {
        let m = model()
        m.saveForm(forward(1, port: "5432"))
        var broken = forward(2, port: "5433")
        broken.instance = ""
        m.forwards.append(broken)

        m.startAll(m.forwards)

        XCTAssertEqual(m.state(for: m.forwards[0]).run, .starting)
        XCTAssertEqual(m.state(for: broken).run, .stopped)
    }

    @MainActor func testStartAllLeavesAlreadyRunningOnesAlone() {
        let m = model()
        m.saveForm(forward(1, port: "5432"))
        m.saveForm(forward(2, port: "5433"))
        m.handle(HelperMessage(event: "started", id: 1, detail: "localhost:5432"))

        m.startAll(m.forwards)

        XCTAssertEqual(m.state(for: m.forwards[0]).run, .running, "not toggled off")
        XCTAssertEqual(m.state(for: m.forwards[1]).run, .starting)
    }

    @MainActor func testStartAllRetriesAnErroredForward() {
        let m = model()
        m.saveForm(forward(1, port: "5432"))
        m.handle(HelperMessage(event: "exited", id: 1, error: "boom"))
        XCTAssertEqual(m.state(for: m.forwards[0]).run, .error)

        m.startAll(m.forwards)
        XCTAssertEqual(m.state(for: m.forwards[0]).run, .starting)
    }

    @MainActor func testAnyLiveIgnoresStoppedAndErrored() {
        let m = model()
        m.saveForm(forward(1, port: "5432"))
        XCTAssertFalse(m.anyLive(in: m.forwards))

        m.handle(HelperMessage(event: "exited", id: 1, error: "boom"))
        XCTAssertFalse(m.anyLive(in: m.forwards), "an errored forward is not running")

        m.handle(HelperMessage(event: "started", id: 1))
        XCTAssertTrue(m.anyLive(in: m.forwards))
    }

    @MainActor func testAnyLiveIgnoresAnOrphanedState() {
        let m = model()
        m.states[99] = EntryState(run: .running)
        XCTAssertFalse(m.anyLive(in: m.forwards), "a state with no row must not drive the button")
    }

    @MainActor func testAGroupStartsOnlyItsOwnForwards() {
        let m = model()
        var db = forward(1, port: "5432", name: "db")
        db.group = "databases"
        var cache = forward(2, port: "6379", name: "cache")
        cache.group = "caches"
        m.saveForm(db)
        m.saveForm(cache)

        let databases = m.groups.first { $0.name == "databases" }!
        m.toggleAll(databases.forwards)

        XCTAssertEqual(m.state(for: m.forwards[0]).run, .starting)
        XCTAssertEqual(m.state(for: m.forwards[1]).run, .stopped, "the other group is untouched")
    }

    @MainActor func testAGroupsButtonOnlyReflectsItsOwnForwards() {
        let m = model()
        var db = forward(1, port: "5432")
        db.group = "databases"
        var cache = forward(2, port: "6379")
        cache.group = "caches"
        m.saveForm(db)
        m.saveForm(cache)
        m.handle(HelperMessage(event: "started", id: 1))

        let databases = m.groups.first { $0.name == "databases" }!
        let caches = m.groups.first { $0.name == "caches" }!

        XCTAssertTrue(m.anyLive(in: databases.forwards))
        XCTAssertFalse(m.anyLive(in: caches.forwards))
        XCTAssertEqual(m.runningCount(in: databases.forwards), 1)
        XCTAssertEqual(m.runningCount(in: caches.forwards), 0)
    }

    @MainActor func testSaveFormTrimsTheGroup() {
        let m = model()
        var typed = forward(1)
        typed.group = "  databases  "
        m.saveForm(typed)

        XCTAssertEqual(m.forwards[0].group, "databases", "a stray space would make a second group")
        XCTAssertEqual(m.groupNames, ["databases"])
    }

    @MainActor func testGroupNamesOffersEachGroupOnce() {
        let m = model()
        for (id, group) in [(1, "databases"), (2, "caches"), (3, "databases"), (4, "")] {
            var f = forward(id, port: "\(6000 + id)")
            f.group = group
            m.saveForm(f)
        }
        XCTAssertEqual(m.groupNames, ["caches", "databases"])
    }

    @MainActor func testLoginsMessageIsStored() {
        let m = model()
        m.handle(
            HelperMessage(
                event: "logins",
                logins: [HelperLogin(label: "company", profiles: ["a", "b"], expires: nil)]))

        XCTAssertEqual(m.logins.map(\.label), ["company"])
        XCTAssertEqual(m.logins[0].profiles, ["a", "b"])
    }

    @MainActor func testSignInMarksTheLoginBusyUntilTheHelperAnswers() {
        let m = model()
        m.logins = [SSOLogin(label: "company")]
        m.signIn(m.logins[0])

        XCTAssertEqual(m.signingIn, "company")
        XCTAssertNil(m.signInError)

        m.handle(HelperMessage(event: "ssoLogin", detail: "company"))
        XCTAssertNil(m.signingIn)
        XCTAssertNil(m.signInError)
    }

    @MainActor func testAFailedSignInReportsAndClearsBusy() {
        let m = model()
        m.logins = [SSOLogin(label: "company")]
        m.signIn(m.logins[0])
        m.handle(HelperMessage(event: "ssoLogin", detail: "company", error: "the AWS CLI is not installed"))

        XCTAssertNil(m.signingIn)
        XCTAssertEqual(m.signInError, "the AWS CLI is not installed")
    }

    @MainActor func testASecondSignInIsIgnoredWhileOneIsRunning() {
        let m = model()
        m.logins = [SSOLogin(label: "company"), SSOLogin(label: "other")]
        m.signIn(m.logins[0])
        m.signIn(m.logins[1])

        XCTAssertEqual(m.signingIn, "company", "double-clicking must not open two browser flows")
    }

    @MainActor func testAnotherLoginsResultDoesNotClearTheRunningOne() {
        let m = model()
        m.logins = [SSOLogin(label: "company"), SSOLogin(label: "other")]
        m.signIn(m.logins[0])
        m.handle(HelperMessage(event: "ssoLogin", detail: "other", error: "stale"))

        XCTAssertEqual(m.signingIn, "company")
        XCTAssertNil(m.signInError, "a result for a different login is not this one's failure")
    }

    @MainActor private func autoModel(_ logins: [SSOLogin]) -> AppModel {
        let m = model()
        m.showSSO = true
        m.autoSignIn = true
        m.logins = logins
        m.screen.lockedOverride = false
        m.presentation.activeOverride = false
        m.dns.resolvedOverride = true
        return m
    }

    @MainActor func testAnExpiredSessionIsSignedInAutomaticallyWhenAsked() {
        let m = autoModel([SSOLogin(label: "company")])
        m.handle(HelperMessage(event: "loginCheck", detail: "company", state: "expired"))

        XCTAssertEqual(m.signingIn, "company", "the whole point of the setting")
    }

    @MainActor func testHidingTheSSORowTurnsAutomaticSignInOff() {
        let m = model()
        m.showSSO = true
        m.autoSignIn = true

        m.showSSO = false

        XCTAssertFalse(
            m.autoSignIn,
            "the setting is nested under the SSO row; hiding the parent must not leave it armed")
        XCTAssertFalse(Preferences.autoSignIn, "and that has to be written through")

        m.showSSO = true
        XCTAssertFalse(m.autoSignIn, "turning the parent back on must not silently re-arm it")
    }

    @MainActor func testAutoSignInIsOffByDefault() {
        let m = model()
        XCTAssertFalse(m.autoSignIn, "opening a browser on its own has to be opted into")

        m.logins = [SSOLogin(label: "company")]
        m.handle(HelperMessage(event: "loginCheck", detail: "company", state: "expired"))
        XCTAssertNil(m.signingIn)
    }

    @MainActor private func path(_ satisfied: Bool) -> PathSnapshot {
        PathSnapshot(satisfied: satisfied, interfaces: ["en0"], gateways: ["192.168.1.1"])
    }

    private let notes = """
        ## v1.0.0

        - Dismiss all errored forwards at once.

        ## v0.9.0

        - Older thing.
        """

    @MainActor func testAFirstRunRecordsTheVersionWithoutAnnouncingIt() {
        let m = model()
        m.announceUpdate(current: "1.0.0", notes: notes)

        XCTAssertFalse(
            m.showingWhatsNew,
            "a fresh install has nothing new to be told about")
        XCTAssertEqual(Preferences.lastSeenVersion, "1.0.0")
    }

    @MainActor func testAnUpdateAnnouncesItselfOnce() {
        Preferences.lastSeenVersion = "0.9.0"
        let m = model()

        m.announceUpdate(current: "1.0.0", notes: notes)
        XCTAssertTrue(m.showingWhatsNew)
        XCTAssertEqual(m.whatsNew.map(\.version), ["1.0.0"])

        m.closeWhatsNew()
        m.announceUpdate(current: "1.0.0", notes: notes)
        XCTAssertFalse(
            m.showingWhatsNew,
            "the version is recorded on the first announce, so a relaunch stays quiet")
    }

    @MainActor func testTheSameVersionNeverAnnounces() {
        Preferences.lastSeenVersion = "1.0.0"
        let m = model()
        m.announceUpdate(current: "1.0.0", notes: notes)

        XCTAssertFalse(m.showingWhatsNew)
    }

    @MainActor func testAnUpdateWithNoMatchingNotesStaysQuiet() {
        Preferences.lastSeenVersion = "1.0.0"
        let m = model()
        m.announceUpdate(current: "1.0.1", notes: notes)

        XCTAssertFalse(
            m.showingWhatsNew,
            "an empty window is worse than none")
        XCTAssertEqual(
            Preferences.lastSeenVersion, "1.0.1",
            "the version still has to be recorded, or it retries on every launch")
    }

    @MainActor func testADevelopmentBuildNeitherAnnouncesNorRecordsAnything() {
        Preferences.lastSeenVersion = "1.0.2"
        let m = model()

        m.announceUpdate(current: "0.0.0-dev", notes: notes)

        XCTAssertFalse(m.showingWhatsNew)
        XCTAssertEqual(
            Preferences.lastSeenVersion, "1.0.2",
            "a local build must not touch the record the installed app keeps")
    }

    @MainActor func testAVersionRecordedByADevelopmentBuildDoesNotReplayTheWholeHistory() {
        Preferences.lastSeenVersion = "0.0.0-dev"
        let m = model()

        m.announceUpdate(current: "1.0.0", notes: notes)

        XCTAssertFalse(
            m.showingWhatsNew,
            "0.0.0 reads as older than every release, which dumped every section ever written")
        XCTAssertEqual(Preferences.lastSeenVersion, "1.0.0")
    }

    @MainActor func testTheRecordedVersionNeverMovesBackwards() {
        Preferences.lastSeenVersion = "1.0.1"
        let m = model()

        m.announceUpdate(current: "0.9.0", notes: notes)

        XCTAssertFalse(m.showingWhatsNew, "an older build has nothing new to announce")
        XCTAssertEqual(
            Preferences.lastSeenVersion, "1.0.1",
            "rewinding it would replay the notes on the way back up")
    }

    @MainActor func testAJumpOfSeveralVersionsStillShowsEveryReleaseBetween() {
        Preferences.lastSeenVersion = "0.8.0"
        let m = model()

        m.announceUpdate(current: "1.0.1", notes: notes)

        XCTAssertTrue(m.showingWhatsNew)
        XCTAssertEqual(
            m.whatsNew.map(\.version), ["1.0.0", "0.9.0"],
            "skipping releases is normal; every section since the last one seen belongs here")
    }

    @MainActor func testWhatsNewCanBeOpenedByHand() {
        let m = model()
        m.openWhatsNew(current: "0.9.0", notes: notes)

        XCTAssertTrue(m.showingWhatsNew)
        XCTAssertEqual(m.whatsNew.map(\.version), ["0.9.0"])
    }

    @MainActor func testAManualSignInShowsItsWindowAtOnce() {
        let m = autoModel([SSOLogin(label: "company")])
        m.signIn(m.logins[0])

        XCTAssertTrue(
            m.showingWebSignIn,
            "the user clicked Sign in; something has to appear immediately")
    }

    @MainActor func testASilentSignInRevealsItsWindowOnlyWhenItStalls() {
        let m = autoModel([SSOLogin(label: "company")])
        m.signIn(m.logins[0], silent: true)

        XCTAssertFalse(
            m.showingWebSignIn,
            "a renewal that completes on the stored cookie must never show a window")

        m.handle(HelperMessage(event: "ssoLoginPending", detail: "company"))
        XCTAssertTrue(m.showingWebSignIn, "past the grace period the user has to see it")

        m.handle(HelperMessage(event: "ssoLogin", detail: "company"))
        XCTAssertFalse(m.showingWebSignIn, "the result closes it")
    }

    @MainActor func testCancellingTheEmbeddedWindowClosesIt() {
        let m = autoModel([SSOLogin(label: "company")])
        m.signIn(m.logins[0], silent: true)
        m.handle(HelperMessage(event: "ssoLoginPending", detail: "company"))
        XCTAssertTrue(m.showingWebSignIn)

        m.cancelWebSignIn()
        XCTAssertFalse(m.showingWebSignIn)
    }

    @MainActor func testAPresentationIsNotSignedInAutomatically() {
        let m = autoModel([SSOLogin(label: "company")])
        m.presentation.activeOverride = true

        m.maybeAutoSignIn()

        XCTAssertNil(
            m.signingIn,
            "a stalled login raises the browser, which lands on whatever is being shared")
    }

    @MainActor func testAPresentationDoesNotConsumeTheBackoff() {
        let m = autoModel([SSOLogin(label: "company")])
        let start = Date()

        m.presentation.activeOverride = true
        m.maybeAutoSignIn(now: start)
        XCTAssertNil(m.signingIn)

        m.presentation.activeOverride = false
        m.maybeAutoSignIn(now: start.addingTimeInterval(1))
        XCTAssertEqual(m.signingIn, "company", "ending the call should sign in, not wait 15 minutes")
    }

    @MainActor func testEveryDeferralIsIndependent() {
        let m = autoModel([SSOLogin(label: "company")])
        XCTAssertFalse(m.deferAutoSignIn, "a normal desk session must not be deferred")

        m.screen.lockedOverride = true
        XCTAssertTrue(m.deferAutoSignIn)
        m.screen.lockedOverride = false

        m.presentation.activeOverride = true
        XCTAssertTrue(m.deferAutoSignIn)
        m.presentation.activeOverride = false

        m.network.observe(path(false))
        XCTAssertTrue(m.deferAutoSignIn)
        m.network.observe(path(true))

        m.dns.resolvedOverride = false
        XCTAssertTrue(m.deferAutoSignIn)
    }

    @MainActor func testAnUnresolvedHostIsNotSignedInAutomatically() {
        let m = autoModel([SSOLogin(label: "company", startURL: "https://portal.example.com/start")])
        m.dns.resolvedOverride = false

        m.maybeAutoSignIn()

        XCTAssertNil(
            m.signingIn,
            "a satisfied path is not a working resolver — the login would fail on DNS")
    }

    @MainActor func testWorkingDNSDoesNotConsumeTheBackoff() {
        let m = autoModel([SSOLogin(label: "company")])
        let start = Date()

        m.dns.resolvedOverride = false
        m.maybeAutoSignIn(now: start)
        XCTAssertNil(m.signingIn)

        m.dns.resolvedOverride = true
        m.maybeAutoSignIn(now: start.addingTimeInterval(1))
        XCTAssertEqual(
            m.signingIn, "company",
            "waiting for the network to settle must not count as an attempt")
    }

    @MainActor func testTheProbedHostIsTheOneTheSignInNeeds() {
        let m = autoModel([SSOLogin(label: "company", startURL: "https://portal.example.com/start")])
        XCTAssertEqual(
            m.signInHost, "portal.example.com",
            "the portal is what a split-DNS VPN fails to resolve, not the internet at large")

        m.logins = [SSOLogin(label: "legacy")]
        XCTAssertEqual(m.signInHost, DNSCheck.fallbackHost, "an unknown start URL still needs a probe")
    }

    @MainActor func testALockedScreenIsNotSignedInAutomatically() {
        let m = autoModel([SSOLogin(label: "company")])
        m.screen.lockedOverride = true

        m.maybeAutoSignIn()

        XCTAssertNil(
            m.signingIn,
            "nobody is there to approve it, and the tab would open behind the lock screen")
    }

    @MainActor func testALockedScreenDoesNotConsumeTheBackoff() {
        let m = autoModel([SSOLogin(label: "company")])
        let start = Date()

        m.screen.lockedOverride = true
        m.maybeAutoSignIn(now: start)
        XCTAssertNil(m.signingIn)

        m.screen.lockedOverride = false
        m.maybeAutoSignIn(now: start.addingTimeInterval(1))
        XCTAssertEqual(
            m.signingIn, "company",
            "unlocking has to sign in at once, not serve out a backoff it never earned")
    }

    @MainActor func testTheRealSignalsAnswerWithoutOverridesOrPermissions() {
        let screen = ScreenLock()
        let presentation = Presentation()

        XCTAssertFalse(
            screen.locked,
            "the session dictionary carries no locked key while the session is in use")
        _ = presentation.active
        _ = Presentation.mirroring()
        _ = Presentation.cameraInUse()
    }

    @MainActor func testAnOfflineMachineIsNotSignedInAutomatically() {
        let m = autoModel([SSOLogin(label: "company")])
        m.network.observe(path(false))

        m.maybeAutoSignIn()

        XCTAssertNil(
            m.signingIn,
            "a login that cannot reach the IdP would fail and burn the backoff")
    }

    @MainActor func testAnOfflineAttemptDoesNotConsumeTheBackoff() {
        let m = autoModel([SSOLogin(label: "company")])
        let start = Date()

        m.network.observe(path(false))
        m.maybeAutoSignIn(now: start)
        XCTAssertNil(m.signingIn)

        m.network.observe(path(true))
        m.maybeAutoSignIn(now: start.addingTimeInterval(1))
        XCTAssertEqual(
            m.signingIn, "company",
            "the offline skip must not count as an attempt, or recovery waits 15 minutes")
    }

    @MainActor func testReachabilityIsAssumedUntilTheMonitorSaysOtherwise() {
        let m = autoModel([SSOLogin(label: "company")])

        XCTAssertTrue(
            m.network.reachable,
            "before the first path update, blocking sign-in would break every launch")
        m.maybeAutoSignIn()
        XCTAssertEqual(m.signingIn, "company")
    }

    @MainActor func testAValidSessionIsLeftAlone() {
        let live = SSOLogin(label: "company", expires: Date().addingTimeInterval(3600))
        let m = autoModel([live])
        m.handle(HelperMessage(event: "loginCheck", detail: "company", state: "valid"))

        XCTAssertNil(m.signingIn)
    }

    @MainActor func testAVanishedTokenIsNoticedWithoutWaitingForTheNextCheck() {
        let m = autoModel([SSOLogin(label: "company", expires: Date().addingTimeInterval(3600))])
        m.checks["company"] = .valid

        m.handle(
            HelperMessage(
                event: "logins", logins: [HelperLogin(label: "company", profiles: ["dev"])]))

        XCTAssertEqual(
            m.signingIn, "company",
            "a token that is gone from the cache cannot be rescued by a five-minute-old verdict")
    }

    @MainActor func testAHiddenSSORowSuppressesTheAutomaticSignIn() {
        let m = autoModel([SSOLogin(label: "company")])
        m.showSSO = false
        m.handle(HelperMessage(event: "loginCheck", detail: "company", state: "expired"))

        XCTAssertNil(
            m.signingIn,
            "the row is the only place its progress and failures are visible")
    }

    @MainActor func testAFailedAutomaticSignInBacksOffBeforeRetrying() {
        let m = autoModel([SSOLogin(label: "company")])
        let start = Date()

        m.maybeAutoSignIn(now: start)
        XCTAssertEqual(m.signingIn, "company")
        m.handle(HelperMessage(event: "ssoLogin", detail: "company", error: "no"))

        m.maybeAutoSignIn(now: start.addingTimeInterval(AppModel.autoSignInBackoff - 1))
        XCTAssertNil(m.signingIn, "a login that keeps failing must not open a tab every poll")

        m.maybeAutoSignIn(now: start.addingTimeInterval(AppModel.autoSignInBackoff + 1))
        XCTAssertEqual(m.signingIn, "company", "but it has to recover on its own eventually")
    }

    @MainActor func testASignInThatReportsSuccessButStaysExpiredDoesNotSpin() {
        let m = autoModel([SSOLogin(label: "company")])
        let start = Date()

        m.checks["company"] = .expired
        m.maybeAutoSignIn(now: start)
        XCTAssertEqual(m.signingIn, "company")

        m.handle(HelperMessage(event: "ssoLogin", detail: "company"), now: start)
        m.checks["company"] = .expired
        m.maybeAutoSignIn(now: start.addingTimeInterval(1))

        XCTAssertNil(
            m.signingIn,
            "exit 0 on a session that still reads expired must not retry with no delay")
    }

    @MainActor func testASessionThatCameBackClearsItsBackoff() {
        let start = Date()
        let m = autoModel([SSOLogin(label: "company", expires: start.addingTimeInterval(3600))])

        m.checks["company"] = .expired
        m.maybeAutoSignIn(now: start)
        m.handle(HelperMessage(event: "ssoLogin", detail: "company", error: "no"))

        m.checks["company"] = .valid
        m.maybeAutoSignIn(now: start.addingTimeInterval(1))

        m.checks["company"] = .expired
        m.maybeAutoSignIn(now: start.addingTimeInterval(2))
        XCTAssertEqual(m.signingIn, "company", "signing in by hand should re-arm the automatic path")
    }

    @MainActor func testAnAutomaticSignInDoesNotInterruptOneInFlight() {
        let m = autoModel([SSOLogin(label: "company"), SSOLogin(label: "other")])
        m.signIn(m.logins[0])
        m.checks["other"] = .expired
        m.maybeAutoSignIn()

        XCTAssertEqual(m.signingIn, "company")
    }

    @MainActor func testASlowSignInIsReportedAsWaitingOnTheUser() {
        let m = autoModel([SSOLogin(label: "company")])
        m.signIn(m.logins[0])
        XCTAssertFalse(m.signInPending)

        m.handle(HelperMessage(event: "ssoLoginPending", detail: "company"))
        XCTAssertTrue(m.signInPending)

        m.handle(HelperMessage(event: "ssoLogin", detail: "company"))
        XCTAssertFalse(m.signInPending, "the result has to clear it or the row lies")
    }

    @MainActor func testAPendingNoticeForAnotherLoginIsIgnored() {
        let m = autoModel([SSOLogin(label: "company"), SSOLogin(label: "other")])
        m.signIn(m.logins[0])
        m.handle(HelperMessage(event: "ssoLoginPending", detail: "other"))

        XCTAssertFalse(m.signInPending)
    }

    @MainActor func testOnlySignedOutLoginsOfferASignInButton() {
        let now = Date()
        let m = model()
        m.logins = [
            SSOLogin(label: "live", expires: now.addingTimeInterval(3600)),
            SSOLogin(label: "renewing", refreshable: true),
            SSOLogin(label: "stale", expires: now.addingTimeInterval(-3600)),
            SSOLogin(label: "no-token"),
        ]

        XCTAssertEqual(m.signedOutLogins(at: now).map(\.label), ["stale", "no-token"])

        m.checks["stale"] = .valid
        m.checks["live"] = .expired
        XCTAssertEqual(
            m.signedOutLogins(at: now).map(\.label), ["live", "no-token"],
            "the API verdict decides, in both directions")
    }

    @MainActor func testEverythingSignedInLeavesNothingToSignIn() {
        let now = Date()
        let m = model()
        m.logins = [SSOLogin(label: "a", refreshable: true), SSOLogin(label: "b", refreshable: true)]

        XCTAssertTrue(m.signedOutLogins(at: now).isEmpty, "the button has to disappear")
    }

    func testTheErrorNoticeReadsCorrectlyForASingleForward() {
        XCTAssertEqual(ContentView.erroredLabel(1), "1 forward errored")
        XCTAssertEqual(ContentView.erroredLabel(3), "3 forwards errored")
    }

    @MainActor func testOnlyUnrenewableSessionsAreNudgedAboutTheScope() {
        let m = model()
        m.logins = [
            SSOLogin(label: "plain"),
            SSOLogin(label: "scoped", scoped: true),
            SSOLogin(label: "already-renewing", refreshable: true),
        ]

        XCTAssertEqual(
            m.unscopedLogins.map(\.label), ["plain"],
            "a session that already renews needs no advice")
    }

    @MainActor func testALoginCheckIsRecordedAgainstItsLabel() {
        let m = model()
        m.handle(HelperMessage(event: "loginCheck", detail: "company", state: "expired"))

        XCTAssertEqual(m.checks["company"], .expired)
        XCTAssertEqual(m.check(for: SSOLogin(label: "company")), .expired)
        XCTAssertEqual(m.check(for: SSOLogin(label: "other")), .unknown)
    }

    @MainActor func testAChecksIsNotRepeatedWithinTheInterval() {
        let m = model()
        m.logins = [SSOLogin(label: "company")]
        let start = Date()

        m.checkLogins(now: start)
        m.handle(HelperMessage(event: "loginCheck", detail: "company", state: "valid"))
        m.checks["company"] = nil

        m.checkLogins(now: start.addingTimeInterval(AppModel.loginCheckInterval - 1))
        XCTAssertNil(m.checks["company"], "a GetCallerIdentity per panel open would be wasteful")

        m.checkLogins(now: start.addingTimeInterval(AppModel.loginCheckInterval + 1))
        m.handle(HelperMessage(event: "loginCheck", detail: "company", state: "valid"))
        XCTAssertEqual(m.checks["company"], .valid, "but it must run again once it is stale")
    }

    @MainActor func testASuccessfulSignInForcesAFreshCheck() {
        let m = model()
        m.logins = [SSOLogin(label: "company")]
        m.handle(HelperMessage(event: "loginCheck", detail: "company", state: "expired"))
        m.signIn(m.logins[0])
        m.handle(HelperMessage(event: "ssoLogin", detail: "company"))

        XCTAssertNil(
            m.checks["company"],
            "the stale verdict must not outlive the sign-in that fixed it")

        m.checkLogins()
        m.handle(HelperMessage(event: "loginCheck", detail: "company", state: "valid"))
        XCTAssertEqual(m.checks["company"], .valid)
    }

    @MainActor func testAFailedSignInKeepsTheOldVerdict() {
        let m = model()
        m.logins = [SSOLogin(label: "company")]
        m.handle(HelperMessage(event: "loginCheck", detail: "company", state: "expired"))
        m.signIn(m.logins[0])
        m.handle(HelperMessage(event: "ssoLogin", detail: "company", error: "boom"))

        XCTAssertEqual(m.checks["company"], .expired, "nothing was fixed, so nothing changed")
    }

    @MainActor func testStartingASignInClearsTheLastComplaint() {
        let m = model()
        m.logins = [SSOLogin(label: "company")]
        m.signIn(m.logins[0])
        m.handle(HelperMessage(event: "ssoLogin", detail: "company", error: "boom"))
        m.signIn(m.logins[0])

        XCTAssertNil(m.signInError)
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

    @MainActor func testADeathRecordsHowLongItHadBeenUp() {
        let m = model()
        m.saveForm(forward(1))

        let start = Date()
        m.handle(HelperMessage(event: "started", id: 1), now: start)
        m.handle(
            HelperMessage(event: "exited", id: 1, error: "the session ended on its own"),
            now: start.addingTimeInterval(7_500))

        XCTAssertEqual(m.states[1]?.run, .error)
        XCTAssertEqual(m.states[1]?.detail, "ran for 2h 5m")
    }

    @MainActor func testAFailureBeforeItEverRanRecordsNoUptime() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "exited", id: 1, error: "not signed in"))

        XCTAssertEqual(m.states[1]?.detail, "", "it never came up, so there is nothing to report")
    }

    @MainActor func testImportOpensTheFormPrefilled() {
        let m = model()
        m.saveForm(forward(1, name: "mine"))

        m.importShared(
            #"{"version":1,"forward":{"instance":"theirs","localPort":"6000","#
                + #""remotePort":"5432","name":"shared db"}}"#)

        XCTAssertTrue(m.showingForm, "the importer reviews it before it is saved")
        XCTAssertEqual(m.editing?.name, "shared db")
        XCTAssertEqual(m.editing?.instance, "theirs")
        XCTAssertNil(m.importError)
        XCTAssertEqual(m.forwards.count, 1, "nothing is saved until the form is")
    }

    @MainActor func testAnImportGetsAFreeIDRatherThanTheSendersOwn() {
        let m = model()
        m.saveForm(forward(1, name: "mine"))

        m.importShared(#"{"version":1,"forward":{"id":1,"instance":"theirs","localPort":"1","remotePort":"2"}}"#)
        let imported = try? XCTUnwrap(m.editing)
        m.saveForm(imported!)

        XCTAssertEqual(m.forwards.count, 2, "an id collision would overwrite the existing row")
        XCTAssertEqual(m.forwards.map(\.instance).sorted(), ["db", "theirs"])
    }

    @MainActor func testAFailedImportReportsAndOpensNothing() {
        let m = model()
        m.importShared("this is not json")

        XCTAssertFalse(m.showingForm)
        XCTAssertNotNil(m.importError)
    }

    @MainActor func testASuccessfulImportClearsAnEarlierComplaint() {
        let m = model()
        m.importShared("rubbish")
        XCTAssertNotNil(m.importError)

        m.importShared(#"{"instance":"theirs","localPort":"1","remotePort":"2"}"#)
        XCTAssertNil(m.importError)
    }

    @MainActor func testSharingProducesImportableText() {
        let m = model()
        m.saveForm(forward(1, name: "mine"))

        let text = Share.encode(m.forwards[0])
        let other = model()
        other.importShared(text)

        XCTAssertEqual(other.editing?.instance, m.forwards[0].instance)
        XCTAssertEqual(other.editing?.localPort, m.forwards[0].localPort)
    }

    @MainActor func testDeletingAForwardCollapsesItsDetail() {
        let m = model()
        m.saveForm(forward(1))
        m.handle(HelperMessage(event: "exited", id: 1, error: "boom"))
        m.toggleErrorDetail(1)

        m.delete(m.forwards[0])
        XCTAssertNil(m.expandedError)
    }

    @MainActor func testErroredListsOnlyForwardsInTheErrorState() {
        let m = model()
        m.forwards = [forward(1, port: "5432"), forward(2, port: "5433"), forward(3, port: "5434")]
        m.handle(HelperMessage(event: "exited", id: 1, error: "boom"))
        m.handle(HelperMessage(event: "started", id: 2))

        XCTAssertEqual(m.errored.map(\.id), [1])
    }

    @MainActor func testDismissErrorsClearsEveryErroredForward() {
        let m = model()
        m.forwards = [forward(1, port: "5432"), forward(2, port: "5433"), forward(3, port: "5434")]
        for id in [1, 2, 3] {
            m.handle(HelperMessage(event: "exited", id: id, error: "boom \(id)"))
        }
        XCTAssertEqual(m.errored.count, 3)

        m.dismissErrors(m.errored)

        XCTAssertTrue(m.errored.isEmpty)
        for id in [1, 2, 3] {
            XCTAssertEqual(m.states[id]?.run, .stopped, "id \(id)")
            XCTAssertEqual(m.states[id]?.error, "", "id \(id)")
        }
        XCTAssertFalse(m.needsAttention, "clearing the errors must clear the menubar badge too")
    }

    @MainActor func testDismissErrorsLeavesHealthyForwardsAlone() {
        let m = model()
        m.forwards = [forward(1, port: "5432"), forward(2, port: "5433")]
        m.handle(HelperMessage(event: "exited", id: 1, error: "boom"))
        m.handle(HelperMessage(event: "started", id: 2))

        m.dismissErrors(m.forwards)

        XCTAssertEqual(m.states[1]?.run, .stopped)
        XCTAssertEqual(m.states[2]?.run, .running, "a running forward must not be stopped by a dismiss")
    }

    @MainActor func testDismissErrorsCollapsesTheExpandedErrorPanel() {
        let m = model()
        m.forwards = [forward(1, port: "5432"), forward(2, port: "5433")]
        m.handle(HelperMessage(event: "exited", id: 1, error: "boom"))
        m.handle(HelperMessage(event: "exited", id: 2, error: "boom"))
        m.toggleErrorDetail(2)
        XCTAssertEqual(m.expandedError, 2)

        m.dismissErrors(m.errored)

        XCTAssertNil(m.expandedError)
    }

    @MainActor func testDismissErrorsOnAnEmptyListIsANoOp() {
        let m = model()
        m.forwards = [forward(1, port: "5432")]
        m.handle(HelperMessage(event: "exited", id: 1, error: "boom"))

        m.dismissErrors([])

        XCTAssertEqual(m.errored.count, 1, "dismissing nothing must not clear anything")
    }

    @MainActor func testStopAllStopsEveryLiveForward() {
        let m = model()
        m.forwards = [forward(1, port: "5432"), forward(2, port: "5433"), forward(3, port: "5434")]
        m.handle(HelperMessage(event: "started", id: 1))
        m.handle(HelperMessage(event: "started", id: 2))

        m.stopAll(m.forwards)

        XCTAssertEqual(m.state(for: m.forwards[0]).run, .stopping)
        XCTAssertEqual(m.state(for: m.forwards[1]).run, .stopping)
        XCTAssertEqual(m.state(for: m.forwards[2]).run, .stopped, "an idle forward must be left alone")
    }

    @MainActor func testStopAllOnAnEmptyListIsANoOp() {
        let m = model()
        m.forwards = [forward(1, port: "5432")]
        m.handle(HelperMessage(event: "started", id: 1))

        m.stopAll([])

        XCTAssertEqual(m.state(for: m.forwards[0]).run, .running)
    }

    @MainActor func testStopAllStopsAReconnectingForward() {
        let m = model()
        m.forwards = [forward(1, port: "5432")]
        m.handle(HelperMessage(event: "started", id: 1))
        m.reconnectLiveForwards(reason: .network, now: Date())
        XCTAssertEqual(m.state(for: m.forwards[0]).run, .reconnecting)

        m.stopAll(m.forwards)
        XCTAssertEqual(
            m.state(for: m.forwards[0]).run, .stopping,
            "a reconnecting forward counts as live, so stopping it must take hold")
    }

    @MainActor func testStopAllLeavesAnErroredForwardAlone() {
        let m = model()
        m.forwards = [forward(1, port: "5432")]
        m.handle(HelperMessage(event: "exited", id: 1, error: "boom"))

        m.stopAll(m.forwards)

        XCTAssertEqual(m.state(for: m.forwards[0]).run, .error, "stopping is not how an error is cleared")
    }

    @MainActor func testStartAllSkipsAPortAlreadyHeldByALiveForward() {
        let m = model()
        m.forwards = [forward(1, port: "5432"), forward(2, port: "5432")]
        m.handle(HelperMessage(event: "started", id: 1))

        m.startAll(m.forwards)

        XCTAssertEqual(
            m.state(for: m.forwards[1]).run, .stopped,
            "two forwards on one port is supported; starting the second must be skipped quietly")
        XCTAssertTrue(m.state(for: m.forwards[1]).error.isEmpty, "and must not raise an error")
    }

    @MainActor func testStartAllLeavesAlreadyRunningForwardsRunning() {
        let m = model()
        m.forwards = [forward(1, port: "5432")]
        m.handle(HelperMessage(event: "started", id: 1))

        m.startAll(m.forwards)

        XCTAssertEqual(m.state(for: m.forwards[0]).run, .running)
    }

    @MainActor func testRefreshLoginsIsSafeWhenDetached() {
        let m = model()
        m.refreshLogins()
        m.checkLogins()
        XCTAssertTrue(m.logins.isEmpty)
    }

    @MainActor func testShareAndImportRoundTripThroughTheClipboard() {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        let m = model()
        var original = forward(1, port: "15432", name: "prod db")
        original.profile = "prod"
        original.region = "eu-west-1"
        original.host = "db.internal"
        original.color = "#FF453A"
        original.group = "databases"
        m.saveForm(original)
        XCTAssertEqual(m.forwards.count, 1, "the fixture must actually be saved so nextID advances")

        m.share(original)
        m.importFromClipboard()

        XCTAssertNil(m.importError)
        XCTAssertTrue(m.showingForm, "an import opens the form so it goes through validation")
        let imported = unwrapOrFail(m.editing)
        XCTAssertEqual(imported?.name, "prod db")
        XCTAssertEqual(imported?.host, "db.internal")
        XCTAssertEqual(imported?.localPort, "15432")
        XCTAssertEqual(imported?.color, "#FF453A")
        XCTAssertEqual(imported?.group, "databases")
        XCTAssertNotEqual(imported?.id, original.id, "the importer always gets a fresh id")
    }

    @MainActor func testImportFromAClipboardHoldingGarbageReportsAnError() {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        let m = model()
        m.copyToClipboard("this is not a forward")
        m.importFromClipboard()

        XCTAssertNotNil(m.importError)
        XCTAssertFalse(m.showingForm, "a failed import must not open an empty form")
    }

    @MainActor func testImportFromAnEmptyClipboardReportsAnError() {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        let m = model()
        m.copyToClipboard("")
        m.importFromClipboard()

        XCTAssertNotNil(m.importError)
        XCTAssertFalse(m.showingForm)
    }

    @MainActor func testShareClearsAStaleImportError() {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        let m = model()
        m.importShared("garbage")
        XCTAssertNotNil(m.importError)

        m.share(forward(1, port: "5432"))
        XCTAssertNil(m.importError, "sharing is a fresh action; a previous import error must clear")
    }

    @MainActor func testCopyToClipboardPutsExactlyTheGivenText() {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        let m = model()
        m.copyToClipboard("session-manager-plugin exited with status 1")
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "session-manager-plugin exited with status 1")
    }

    @MainActor private func quickConnect(_ m: AppModel, port: String = "6099") -> Forward {
        m.beginQuickConnect()
        var draft = m.editing ?? Forward(id: -1)
        draft.name = "one-off"
        draft.instance = "db"
        draft.localPort = port
        draft.remotePort = "5432"
        m.saveForm(draft)
        return m.temporaries.last ?? draft
    }

    @MainActor func testQuickConnectStartsAForwardThatIsNeverSaved() {
        let m = model()
        let temp = quickConnect(m)

        XCTAssertEqual(m.temporaries.count, 1)
        XCTAssertTrue(m.forwards.isEmpty, "a temporary must not join the saved list")
        XCTAssertTrue(Store.load().forwards.isEmpty, "and nothing may reach forwards.json")
        XCTAssertEqual(m.state(for: temp).run, .starting, "connecting is the whole point")
        XCTAssertFalse(m.showingForm)
    }

    @MainActor func testATemporaryIsListedFirstAndCountedAsRunning() {
        let m = model()
        m.saveForm(forward(1, port: "5432", name: "saved"))
        let temp = quickConnect(m)
        m.handle(HelperMessage(event: "started", id: temp.id))

        XCTAssertEqual(m.groups.map(\.name), [ForwardGroup.temporaryName, ""])
        XCTAssertEqual(m.groups[0].forwards.map(\.id), [temp.id])
        XCTAssertEqual(m.runningCount, 1)
        XCTAssertEqual(m.forwards.count, 1, "the saved count must not include it")
    }

    @MainActor func testATemporaryDisappearsWhenItStops() {
        let m = model()
        let temp = quickConnect(m)
        m.handle(HelperMessage(event: "started", id: temp.id))

        m.toggle(temp)
        m.handle(HelperMessage(event: "exited", id: temp.id))

        XCTAssertTrue(m.temporaries.isEmpty, "stopping a temporary is what disposes of it")
        XCTAssertNil(m.states[temp.id], "and its state must not linger as an orphan")
    }

    @MainActor func testAnErroredTemporaryStaysUntilItIsDismissed() {
        let m = model()
        let temp = quickConnect(m)
        m.handle(HelperMessage(event: "started", id: temp.id))
        m.handle(HelperMessage(event: "exited", id: temp.id, error: "connection lost"))

        XCTAssertEqual(m.temporaries.count, 1, "removing the row would take the message with it")
        XCTAssertEqual(m.state(for: temp).run, .error)
        XCTAssertEqual(m.errored.map(\.id), [temp.id])

        m.dismissError(temp)
        XCTAssertTrue(m.temporaries.isEmpty, "dismissing is the only way out of an errored temporary")
        XCTAssertNil(m.states[temp.id])
    }

    @MainActor func testARunningTemporaryDoesNotBlockAReload() throws {
        let m = model()
        m.saveForm(forward(1, name: "mine"))
        let temp = quickConnect(m)
        m.handle(HelperMessage(event: "started", id: temp.id))

        let external =
            #"{"version":1,"forwards":[{"id":9,"instance":"ext","localPort":"1","name":"external","remotePort":"2"}]}"#
        try Data(external.utf8).write(to: Store.fileURL)

        m.refreshIfChanged()

        XCTAssertEqual(
            m.forwards.map(\.name), ["external"],
            "a temporary is never in the file, so it can never be orphaned by a reload")
        XCTAssertEqual(m.temporaries.count, 1, "and it must survive the reload")
        XCTAssertNil(m.dataNotice)
    }

    @MainActor func testTemporaryIDsCannotCollideWithSavedOnes() {
        let m = model()
        let first = quickConnect(m, port: "6001")
        m.handle(HelperMessage(event: "started", id: first.id))
        let second = quickConnect(m, port: "6002")
        m.saveForm(forward(1, port: "5432"))

        XCTAssertTrue(first.id < 0, "a negative id is what marks a forward as unsaved")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(m.forwards.map(\.id), [1], "saved ids carry on from 1 regardless")
    }

    @MainActor func testATemporaryCarriesNoShortcutOrGroupOfItsOwn() {
        let m = model()
        m.beginQuickConnect()
        var draft = m.editing ?? Forward(id: -1)
        draft.instance = "db"
        draft.localPort = "6099"
        draft.remotePort = "5432"
        draft.group = "db"
        draft.hotKey = HotKey(keyCode: 19, carbonModifiers: UInt32(cmdKey | controlKey))
        m.saveForm(draft)

        XCTAssertEqual(m.temporaries[0].group, ForwardGroup.temporaryName)
        XCTAssertNil(
            m.temporaries[0].hotKey,
            "a shortcut for a row that disposes of itself would outlive the row")
    }

    @MainActor func testAnInvalidQuickConnectKeepsTheFormOpen() {
        let m = model()
        m.beginQuickConnect()
        var draft = m.editing ?? Forward(id: -1)
        draft.localPort = "6099"
        m.saveForm(draft)

        XCTAssertTrue(m.temporaries.isEmpty)
        XCTAssertTrue(m.showingForm, "the form has to stay up to show what is wrong")
        XCTAssertNotNil(m.formError)
    }

    @MainActor func testDeletingATemporaryLeavesTheStoreAlone() {
        let m = model()
        m.saveForm(forward(1, name: "mine"))
        let temp = quickConnect(m)

        m.delete(temp)

        XCTAssertTrue(m.temporaries.isEmpty)
        XCTAssertEqual(Store.load().forwards.map(\.name), ["mine"])
        XCTAssertNil(m.states[temp.id])
    }

    @MainActor func testATemporaryHoldingAPortStopsASavedOneStarting() {
        let m = model()
        let temp = quickConnect(m, port: "6099")
        m.handle(HelperMessage(event: "started", id: temp.id))
        m.saveForm(forward(1, port: "6099", name: "saved"))

        m.toggle(m.forwards[0])

        XCTAssertEqual(m.state(for: m.forwards[0]).run, .error)
        XCTAssertTrue(m.state(for: m.forwards[0]).error.contains("6099"))
    }

    @MainActor func testTestingADraftWaitsForTheHelper() {
        let m = model()
        m.beginAdd()

        m.testForm(forward(1))

        XCTAssertEqual(m.testing, 1)
        XCTAssertNil(m.testOutcome, "no verdict may be shown before one arrives")
        XCTAssertNil(m.formError)
    }

    @MainActor func testAPassingTestIsReported() {
        let m = model()
        m.testForm(forward(1))
        m.handle(HelperMessage(event: "test", id: 1, detail: "db (i-0abc) is running"))

        XCTAssertNil(m.testing)
        XCTAssertEqual(m.testOutcome?.ok, true)
        XCTAssertEqual(m.testOutcome?.message, "db (i-0abc) is running")
    }

    @MainActor func testAFailingTestCarriesTheReason() {
        let m = model()
        m.testForm(forward(1))
        m.handle(HelperMessage(event: "test", id: 1, error: "AWS profile \"ghost\" does not exist"))

        XCTAssertNil(m.testing)
        XCTAssertEqual(m.testOutcome?.ok, false)
        XCTAssertTrue(m.testOutcome?.message.contains("ghost") ?? false)
    }

    @MainActor func testAResultForSomethingElseIsIgnored() {
        let m = model()
        m.testForm(forward(1))
        m.handle(HelperMessage(event: "test", id: 2, detail: "another draft"))

        XCTAssertEqual(m.testing, 1, "a reply for another draft must not end this test")
        XCTAssertNil(m.testOutcome)
    }

    @MainActor func testALateResultAfterTheFormClosedIsDropped() {
        let m = model()
        m.beginAdd()
        m.testForm(forward(1))
        m.cancelForm()
        m.handle(HelperMessage(event: "test", id: 1, detail: "too late"))

        XCTAssertNil(m.testing)
        XCTAssertNil(m.testOutcome)
    }

    @MainActor func testTestingAnIncompleteDraftAsksForTheInstanceOnly() {
        let m = model()
        var draft = Forward(id: 1)
        draft.localPort = ""
        draft.remotePort = ""

        m.testForm(draft)

        XCTAssertNil(m.testing, "there is nothing to look up without an instance")
        XCTAssertNotNil(m.formError)
    }

    @MainActor func testALocalPortIsNotNeededToTestATarget() {
        let m = model()
        var draft = Forward(id: 1)
        draft.instance = "db"
        draft.remotePort = "5432"

        m.testForm(draft)

        XCTAssertEqual(m.testing, 1, "the test opens its own local port, so the field is not needed")
        XCTAssertNil(m.formError)
    }

    @MainActor func testTheRemotePortIsNeededToTestATarget() {
        let m = model()
        var draft = Forward(id: 1)
        draft.instance = "db"
        draft.localPort = "15432"

        m.testForm(draft)

        XCTAssertNil(m.testing, "there is nothing to connect to without a remote port")
        XCTAssertEqual(m.formError, "Remote port must be a number 1–65535.")
    }

    @MainActor func testAPortHeldByALiveForwardFailsTheTestWithoutAsking() {
        let m = model()
        m.saveForm(forward(1, port: "6099", name: "live"))
        m.toggle(m.forwards[0])
        m.handle(HelperMessage(event: "started", id: 1))

        m.testForm(forward(2, port: "6099"))

        XCTAssertNil(m.testing, "the answer is already known here")
        XCTAssertEqual(m.testOutcome?.ok, false)
        XCTAssertTrue(m.testOutcome?.message.contains("live") ?? false)
    }

    @MainActor func testARunningForwardIsTestedWithoutItsOwnLocalPort() {
        let m = model()
        m.saveForm(forward(1, port: "15432", name: "live"))
        let live = m.forwards[0]

        XCTAssertEqual(m.testSpec(for: live).local, "15432")

        m.toggle(live)
        m.handle(HelperMessage(event: "started", id: 1))

        XCTAssertEqual(
            m.testSpec(for: live).local, "",
            "its own listener holds the port; binding it would report a conflict with itself")
        XCTAssertEqual(m.testSpec(for: live).remote, "5432", "the target is still tested")
    }

    @MainActor func testAnUnusableLocalPortIsRejectedBeforeTheHelper() {
        let m = model()
        var draft = Forward(id: 1)
        draft.instance = "db"
        draft.remotePort = "5432"
        draft.localPort = "not a port"

        m.testForm(draft)

        XCTAssertNil(m.testing)
        XCTAssertEqual(m.formError, "Local port must be a number 1–65535.")
    }

    @MainActor func testASecondTestIsNotStartedWhileOneIsRunning() {
        let m = model()
        m.testForm(forward(1))
        m.testForm(forward(2))

        XCTAssertEqual(m.testing, 1)
    }

    @MainActor func testOpeningTheFormClearsAnOlderVerdict() {
        let m = model()
        m.testForm(forward(1))
        m.handle(HelperMessage(event: "test", id: 1, detail: "worked"))

        m.beginEdit(forward(1))
        XCTAssertNil(m.testOutcome, "a verdict about the last draft would read as this one's")

        m.testForm(forward(1))
        m.handle(HelperMessage(event: "test", id: 1, detail: "worked"))
        m.saveForm(forward(1))
        XCTAssertNil(m.testOutcome)
    }
}

extension AppModelTests {
    fileprivate func unwrapOrFail<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) -> T? {
        if value == nil { XCTFail("expected a value", file: file, line: line) }
        return value
    }
}
