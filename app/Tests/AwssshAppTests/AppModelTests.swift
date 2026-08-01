import AppKit
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
}

extension AppModelTests {
    fileprivate func unwrapOrFail<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) -> T? {
        if value == nil { XCTFail("expected a value", file: file, line: line) }
        return value
    }
}
