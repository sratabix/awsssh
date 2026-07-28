import Carbon.HIToolbox
import XCTest

@testable import AwssshApp

final class ShareTests: XCTestCase {
    private func sample() -> Forward {
        var f = Forward(id: 3)
        f.name = "prod db"
        f.profile = "prod"
        f.region = "eu-central-1"
        f.instance = "bastion"
        f.localPort = "5432"
        f.host = "db.internal"
        f.remotePort = "5432"
        f.hotKey = HotKey(keyCode: 1, carbonModifiers: UInt32(cmdKey))
        return f
    }

    func testARoundTripKeepsEveryField() throws {
        let payload = try Share.decode(Share.encode(sample()))
        let back = Share.forward(from: payload, id: 9)

        XCTAssertEqual(back.name, "prod db")
        XCTAssertEqual(back.profile, "prod")
        XCTAssertEqual(back.region, "eu-central-1")
        XCTAssertEqual(back.instance, "bastion")
        XCTAssertEqual(back.localPort, "5432")
        XCTAssertEqual(back.host, "db.internal")
        XCTAssertEqual(back.remotePort, "5432")
    }

    func testTheHotKeyIsNeverShared() throws {
        let text = Share.encode(sample())
        XCTAssertFalse(text.contains("hotKey"), "a shortcut is personal and would collide")

        let back = Share.forward(from: try Share.decode(text), id: 9)
        XCTAssertNil(back.hotKey)
    }

    func testTheIDIsTheImportersOwn() throws {
        let back = Share.forward(from: try Share.decode(Share.encode(sample())), id: 42)
        XCTAssertEqual(back.id, 42, "the sender's id means nothing on another machine")
    }

    func testTheSharedTextIsReadable() {
        let text = Share.encode(sample())
        XCTAssertTrue(text.contains("\n"), "pretty printed so it survives a chat message")
        XCTAssertTrue(text.contains("\"version\" : 1"))
    }

    func testABareForwardObjectIsAccepted() throws {
        let payload = try Share.decode(#"{"instance":"bastion","localPort":"1","remotePort":"2"}"#)
        XCTAssertEqual(payload.instance, "bastion", "someone pasting just the inner object")
    }

    func testMissingFieldsFallBackToEmpty() throws {
        let payload = try Share.decode(#"{"version":1,"forward":{"instance":"only"}}"#)
        XCTAssertEqual(payload.instance, "only")
        XCTAssertEqual(payload.host, "", "a missing key must not fail the whole import")
    }

    func testAnUnknownFieldIsIgnored() throws {
        let payload = try Share.decode(
            #"{"version":7,"forward":{"instance":"future","somethingNew":true}}"#)
        XCTAssertEqual(payload.instance, "future", "a newer sender must still import")
    }

    func testRubbishIsRejected() {
        XCTAssertThrowsError(try Share.decode("not json at all"))
        XCTAssertThrowsError(try Share.decode(""))
        XCTAssertThrowsError(try Share.decode("   "))
    }

    func testJSONThatIsNotAForwardIsRejected() {
        XCTAssertThrowsError(try Share.decode(#"{"hello":"world"}"#)) { error in
            XCTAssertEqual(
                (error as? ShareError)?.errorDescription,
                ShareError.notAForward.errorDescription,
                "an empty instance is the tell")
        }
    }

    func testControlCharactersAreStripped() throws {
        let payload = try Share.decode(
            #"{"instance":"bas\ntion","name":"a\tb\u0000c","localPort":"1","remotePort":"2"}"#)

        XCTAssertEqual(payload.instance, "bastion")
        XCTAssertEqual(payload.name, "abc", "a newline in a field reaches the plugin as an argument")
    }

    func testBidiOverridesAreStripped() throws {
        let payload = try Share.decode(
            #"{"instance":"prod\u202Egnitset","name":"\u202Dsafe","localPort":"1","remotePort":"2"}"#)

        XCTAssertEqual(
            payload.instance, "prodgnitset",
            "a right-to-left override can make a name render as something else entirely")
        XCTAssertEqual(payload.name, "safe")
    }

    func testFieldsAreLengthCapped() throws {
        let long = String(repeating: "x", count: 5_000)
        let payload = try Share.decode(
            #"{"instance":"ok","name":"\#(long)","localPort":"1","remotePort":"2"}"#)

        XCTAssertEqual(
            payload.name.count, Share.maxFieldLength,
            "an unbounded name would be persisted to forwards.json verbatim")
    }

    func testSurroundingWhitespaceInAFieldIsTrimmed() throws {
        let payload = try Share.decode(
            #"{"instance":"  bastion  ","localPort":" 1 ","remotePort":"2"}"#)

        XCTAssertEqual(payload.instance, "bastion", "a stray space becomes a confusing AWS failure")
        XCTAssertEqual(payload.localPort, "1")
    }

    func testAWhitespaceOnlyInstanceIsNotAForward() {
        XCTAssertThrowsError(
            try Share.decode(#"{"instance":"   ","localPort":"1","remotePort":"2"}"#))
    }

    func testWhitespaceAroundThePasteIsTolerated() throws {
        let text = "\n  " + Share.encode(sample()) + "  \n"
        XCTAssertEqual(try Share.decode(text).instance, "bastion")
    }
}
