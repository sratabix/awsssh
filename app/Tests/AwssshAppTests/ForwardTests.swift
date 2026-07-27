import XCTest

@testable import AwssshApp

final class ForwardTests: XCTestCase {
    private func complete(_ mutate: (inout Forward) -> Void = { _ in }) -> Forward {
        var f = Forward(id: 1)
        f.instance = "db"
        f.localPort = "5432"
        f.remotePort = "5432"
        mutate(&f)
        return f
    }

    func testCompleteForwardValidates() {
        XCTAssertNil(complete().validate())
    }

    func testInstanceIsRequired() {
        XCTAssertNotNil(complete { $0.instance = "" }.validate())
        XCTAssertNotNil(complete { $0.instance = "   " }.validate())
        XCTAssertNotNil(complete { $0.instance = "\t" }.validate())
    }

    func testInstanceMessageNamesTheField() {
        let message = complete { $0.instance = "" }.validate() ?? ""
        XCTAssertTrue(message.lowercased().contains("instance"), message)
    }

    func testLocalPortMustBeNumeric() {
        for value in ["", "abc", "54 32", "5432x", "-1", "0", "65536", "99999", "1.5"] {
            XCTAssertNotNil(complete { $0.localPort = value }.validate(), "localPort \(value) should be rejected")
        }
    }

    func testRemotePortMustBeNumeric() {
        for value in ["", "abc", "0", "65536", "-5"] {
            XCTAssertNotNil(complete { $0.remotePort = value }.validate(), "remotePort \(value) should be rejected")
        }
    }

    func testPortBoundariesAreAccepted() {
        for value in ["1", "80", "65535"] {
            XCTAssertNil(complete { $0.localPort = value }.validate(), "localPort \(value) should be accepted")
            XCTAssertNil(complete { $0.remotePort = value }.validate(), "remotePort \(value) should be accepted")
        }
    }

    func testOptionalFieldsAreOptional() {
        XCTAssertNil(complete { $0.name = "" }.validate())
        XCTAssertNil(complete { $0.profile = "" }.validate())
        XCTAssertNil(complete { $0.region = "" }.validate())
        XCTAssertNil(complete { $0.host = "" }.validate())
        XCTAssertNil(complete { $0.hotKey = nil }.validate())
    }

    func testProfileLabelFallsBackToDefault() {
        XCTAssertEqual(complete { $0.profile = "" }.profileLabel, "default")
        XCTAssertEqual(complete { $0.profile = "prod" }.profileLabel, "prod")
    }

    func testTargetDescribesTheInstanceWhenNoHostIsSet() {
        XCTAssertEqual(complete { $0.host = "" }.target, "instance:5432")
    }

    func testTargetDescribesTheRemoteHost() {
        let f = complete {
            $0.host = "db.internal"
            $0.remotePort = "3306"
        }
        XCTAssertEqual(f.target, "db.internal:3306")
    }

    func testRouteShowsBothEnds() {
        let f = complete {
            $0.localPort = "3307"
            $0.host = "db.internal"
            $0.remotePort = "3306"
        }
        XCTAssertEqual(f.route, "3307 → db.internal:3306")
    }

    func testTitlePrefersTheNameThenTheRoute() {
        XCTAssertEqual(complete { $0.name = "postgres" }.title, "postgres")
        XCTAssertEqual(complete { $0.name = "" }.title, complete { $0.name = "" }.route)
    }

    func testCodableRoundTripKeepsEveryField() throws {
        var f = complete {
            $0.name = "pg"
            $0.profile = "prod"
            $0.region = "eu-west-1"
            $0.host = "db.internal"
        }
        f.hotKey = HotKey(keyCode: 11, carbonModifiers: 256)

        let data = try JSONEncoder().encode(f)
        XCTAssertEqual(try JSONDecoder().decode(Forward.self, from: data), f)
    }

    func testDecodingRequiresAnID() {
        let data = Data(#"{"instance":"db"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Forward.self, from: data))
    }

    func testDecodingFillsMissingOptionalFields() throws {
        let f = try JSONDecoder().decode(Forward.self, from: Data(#"{"id":5}"#.utf8))
        XCTAssertEqual(f.id, 5)
        XCTAssertEqual(f.name, "")
        XCTAssertEqual(f.profile, "")
        XCTAssertEqual(f.region, "")
        XCTAssertEqual(f.instance, "")
        XCTAssertEqual(f.localPort, "")
        XCTAssertEqual(f.host, "")
        XCTAssertEqual(f.remotePort, "")
        XCTAssertNil(f.hotKey)
    }

    func testDecodingIgnoresUnknownFields() throws {
        let f = try JSONDecoder().decode(Forward.self, from: Data(#"{"id":2,"legacyField":"x"}"#.utf8))
        XCTAssertEqual(f.id, 2)
    }

    func testDecodingDropsAnUnusableHotKeyButKeepsTheForward() throws {
        let data = Data(#"{"id":3,"instance":"db","hotKey":{"keyCode":11,"modifiers":0}}"#.utf8)
        let f = try JSONDecoder().decode(Forward.self, from: data)
        XCTAssertEqual(f.instance, "db")
        XCTAssertNil(f.hotKey)
    }

    func testEquatableComparesEveryField() {
        let base = complete()
        XCTAssertEqual(base, complete())
        XCTAssertNotEqual(base, complete { $0.name = "different" })
        XCTAssertNotEqual(base, complete { $0.localPort = "1" })
        XCTAssertNotEqual(base, complete { $0.hotKey = HotKey(keyCode: 11, carbonModifiers: 256) })
    }

    func testIdentifiableUsesTheID() {
        XCTAssertEqual(Forward(id: 42).id, 42)
    }

    func testEntryStateDefaultsToStopped() {
        let state = EntryState()
        XCTAssertEqual(state.run, .stopped)
        XCTAssertEqual(state.detail, "")
        XCTAssertEqual(state.error, "")
    }
}
