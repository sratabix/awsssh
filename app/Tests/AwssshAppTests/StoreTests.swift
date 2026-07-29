import XCTest
@testable import AwssshApp

final class StoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("awsssh-tests-\(UUID().uuidString)")
        Store.directoryOverride = tempDirectory
    }

    override func tearDown() {
        Store.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func data(_ s: String) -> Data { Data(s.utf8) }

    private func forward(_ n: Int) -> Forward {
        var f = Forward(id: n)
        f.name = "mine\(n)"
        f.instance = "i"
        f.localPort = "1\(n)"
        f.remotePort = "2\(n)"
        return f
    }

    private func envelope(_ forwards: [Forward]) -> Data {
        struct Env: Encodable {
            var version: Int
            var forwards: [Forward]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(Env(version: Store.currentVersion, forwards: forwards))
    }

    func testLegacyBareArrayMigrates() {
        let legacy = data(
            """
            [{"id":1,"instance":"db","localPort":"5432","name":"pg","profile":"prod",\
            "region":"eu-west-1","remotePort":"5432","host":""}]
            """)
        let out = Store.decode(legacy)

        XCTAssertEqual(out.forwards.count, 1)
        XCTAssertEqual(out.forwards.first?.name, "pg")
        XCTAssertEqual(out.version, Store.currentVersion)
        XCTAssertEqual(out.backupTag, "v0")
        XCTAssertNil(out.notice)
    }

    func testMissingFieldsFallBackToDefaults() {
        let out = Store.decode(data(#"{"version":1,"forwards":[{"id":7,"instance":"web"}]}"#))

        XCTAssertEqual(out.forwards.count, 1)
        XCTAssertEqual(out.forwards.first?.instance, "web")
        XCTAssertEqual(out.forwards.first?.name, "")
        XCTAssertEqual(out.forwards.first?.localPort, "")
        XCTAssertNil(out.forwards.first?.hotKey)
    }

    func testUnknownFieldsAreIgnored() {
        let out = Store.decode(data(#"{"version":1,"forwards":[{"id":1,"instance":"a","removedField":"x"}]}"#))
        XCTAssertEqual(out.forwards.count, 1)
    }

    func testOneCorruptRecordDoesNotLoseTheRest() {
        let out = Store.decode(
            data(
                """
                {"version":1,"forwards":[{"id":1,"instance":"good"},{"instance":"no-id"},{"id":3,"instance":"also-good"}]}
                """))
        XCTAssertEqual(out.forwards.map(\.instance), ["good", "also-good"])
    }

    func testFutureVersionIsReadableWarnedAndBackedUp() {
        let out = Store.decode(data(#"{"version":99,"forwards":[{"id":1,"instance":"tomorrow"}]}"#))

        XCTAssertEqual(out.forwards.count, 1)
        XCTAssertEqual(out.version, 99)
        XCTAssertEqual(out.backupTag, "v99")
        XCTAssertNotNil(out.notice)
    }

    func testUnreadableFileIsBackedUpNotWiped() {
        let out = Store.decode(data("not json at all"))

        XCTAssertTrue(out.forwards.isEmpty)
        XCTAssertEqual(out.backupTag, "unreadable")
        XCTAssertNotNil(out.notice)
    }

    func testSaveShapeRoundTrips() {
        var forward = Forward(id: 42)
        forward.name = "round"
        forward.instance = "trip"
        forward.localPort = "1"
        forward.remotePort = "2"

        let out = Store.decode(envelope([forward]))
        XCTAssertEqual(out.forwards, [forward])
        XCTAssertNil(out.notice)
        XCTAssertNil(out.backupTag)
    }

    func testEmptyListLoads() {
        XCTAssertTrue(Store.decode(data(#"{"version":1,"forwards":[]}"#)).forwards.isEmpty)
    }

    func testMigrateFromZeroPreservesData() {
        let forward = Forward(id: 1)
        XCTAssertEqual(Store.migrate([forward], from: 0), [forward])
    }

    func testModifierlessHotKeyIsRejectedWithoutLosingTheForward() {
        let out = Store.decode(
            data(#"{"version":1,"forwards":[{"id":1,"instance":"a","hotKey":{"keyCode":11,"modifiers":0}}]}"#))

        XCTAssertEqual(out.forwards.count, 1)
        XCTAssertEqual(out.forwards.first?.instance, "a")
        XCTAssertNil(out.forwards.first?.hotKey)
    }

    func testOutOfRangeHotKeyValuesAreRejected() {
        let junkModifiers = Store.decode(
            data(#"{"version":1,"forwards":[{"id":1,"instance":"a","hotKey":{"keyCode":11,"modifiers":999999}}]}"#))
        XCTAssertNil(junkModifiers.forwards.first?.hotKey)

        let junkKey = Store.decode(
            data(#"{"version":1,"forwards":[{"id":1,"instance":"a","hotKey":{"keyCode":99999,"modifiers":256}}]}"#))
        XCTAssertNil(junkKey.forwards.first?.hotKey)

        let valid = Store.decode(
            data(#"{"version":1,"forwards":[{"id":1,"instance":"a","hotKey":{"keyCode":11,"modifiers":256}}]}"#))
        XCTAssertEqual(valid.forwards.first?.hotKey?.displayString, "⌘B")
    }

    func testDuplicateIDsAreMadeUnique() {
        let out = Store.decode(
            data(#"{"version":1,"forwards":[{"id":1,"instance":"first"},{"id":1,"instance":"second"}]}"#))

        XCTAssertEqual(out.forwards.map(\.instance), ["first", "second"])
        XCTAssertEqual(Set(out.forwards.map(\.id)).count, 2)
        XCTAssertEqual(out.backupTag, "repaired")
    }

    func testNonPositiveIDsAreReplaced() {
        let out = Store.decode(
            data(#"{"version":1,"forwards":[{"id":0,"instance":"zero"},{"id":-4,"instance":"neg"}]}"#))
        XCTAssertTrue(out.forwards.allSatisfy { $0.id > 0 })
        XCTAssertEqual(Set(out.forwards.map(\.id)).count, 2)
    }

    func testDuplicateHotKeyKeptOnFirstForwardOnly() {
        let json = #"""
            {"version":1,"forwards":[\
            {"id":1,"instance":"a","localPort":"1","remotePort":"2","hotKey":{"keyCode":11,"modifiers":256}},\
            {"id":2,"instance":"b","localPort":"3","remotePort":"4","hotKey":{"keyCode":11,"modifiers":256}}]}
            """#
        let out = Store.decode(data(json.replacingOccurrences(of: "\\\n", with: "")))

        XCTAssertNotNil(out.forwards.first?.hotKey)
        XCTAssertNil(out.forwards.last?.hotKey)
        XCTAssertEqual(out.backupTag, "repaired")
        XCTAssertTrue(out.notice?.contains("only the first keeps it") == true)
    }

    func testIncompleteForwardsAreReportedNotDiscardedOrBackedUp() {
        let out = Store.decode(data(#"{"version":1,"forwards":[{"id":1,"instance":"","localPort":"abc"}]}"#))

        XCTAssertEqual(out.forwards.count, 1)
        XCTAssertTrue(out.notice?.contains("incomplete settings") == true)
        XCTAssertNil(out.backupTag)
    }

    func testCleanFileProducesNoNoticeOrBackup() {
        let out = Store.decode(
            data(#"{"version":1,"forwards":[{"id":1,"instance":"ok","localPort":"5432","remotePort":"5432"}]}"#))
        XCTAssertNil(out.notice)
        XCTAssertNil(out.backupTag)
    }

    private var conflictBackup: URL {
        tempDirectory.appendingPathComponent("forwards.conflict.backup.json")
    }

    func testSaveThenLoadRoundTripsOnDisk() {
        _ = Store.save([forward(1)], expecting: nil)
        let out = Store.load()

        XCTAssertEqual(out.forwards.map(\.name), ["mine1"])
        XCTAssertNotNil(out.stamp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: conflictBackup.path))
    }

    func testLoadOfAMissingFileIsEmptyAndQuiet() {
        let out = Store.load()
        XCTAssertTrue(out.forwards.isEmpty)
        XCTAssertNil(out.notice)
        XCTAssertNil(out.stamp)
    }

    func testExternalChangeIsBackedUpBeforeBeingOverwritten() throws {
        _ = Store.save([forward(1)], expecting: nil)
        let ourStamp = Store.load().stamp

        let external =
            #"{"version":1,"forwards":[{"id":42,"instance":"ext","localPort":"999","name":"EXTERNAL","remotePort":"999"}]}"#
        try Data(external.utf8).write(to: Store.fileURL)
        XCTAssertNotEqual(Store.stamp(), ourStamp)

        _ = Store.save([forward(1), forward(2)], expecting: ourStamp)

        XCTAssertTrue(FileManager.default.fileExists(atPath: conflictBackup.path))
        let rescued = Store.decode(try Data(contentsOf: conflictBackup))
        XCTAssertEqual(rescued.forwards.first?.name, "EXTERNAL")
        XCTAssertEqual(Store.load().forwards.map(\.name), ["mine1", "mine2"])
    }

    func testSaveWithCurrentStampMakesNoConflictBackup() {
        _ = Store.save([forward(1)], expecting: nil)
        _ = Store.save([forward(1), forward(2)], expecting: Store.stamp())

        XCTAssertFalse(FileManager.default.fileExists(atPath: conflictBackup.path))
        XCTAssertEqual(Store.load().forwards.count, 2)
    }

    func testRevealTargetIsTheDirectoryUntilThereIsAFile() {
        let before = Store.revealTarget()
        XCTAssertEqual(
            before.path, Store.directory.path,
            "selecting a file that does not exist yet would open nothing")

        _ = Store.save([forward(1)], expecting: nil)
        XCTAssertEqual(Store.revealTarget().path, Store.fileURL.path)
    }

    func testLegacyFileOnDiskIsBackedUpOnLoad() throws {
        try Data(#"[{"id":1,"instance":"old","localPort":"1","remotePort":"2"}]"#.utf8)
            .write(to: Store.fileURL)

        let out = Store.load()
        XCTAssertEqual(out.forwards.count, 1)
        XCTAssertEqual(out.version, Store.currentVersion)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDirectory.appendingPathComponent("forwards.v0.backup.json").path))
    }
}
