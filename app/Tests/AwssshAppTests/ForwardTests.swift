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
        XCTAssertEqual(f.color, "")
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

    func testPortsRejectEverythingThatIsNotAPlainNumber() {
        let rejected = [
            " 5432", "5432 ", "5432\n", "5432.0", "54_32", "abc", "",
            "５４３２", "٥٤٣٢", "0x10", "1e3", "-1",
        ]
        for value in rejected {
            var f = Forward(id: 1)
            f.instance = "db"
            f.localPort = value
            f.remotePort = "5432"
            XCTAssertNotNil(f.validate(), "local port \(value.debugDescription) must be rejected")

            f.localPort = "5432"
            f.remotePort = value
            XCTAssertNotNil(f.validate(), "remote port \(value.debugDescription) must be rejected")
        }
    }

    func testPortsRejectZeroAndAnythingAbove65535() {
        for value in ["0", "65536", "70000", "99999999999999999999"] {
            var f = Forward(id: 1)
            f.instance = "db"
            f.localPort = value
            f.remotePort = "5432"
            XCTAssertNotNil(f.validate(), "port \(value) is out of range")
        }
    }

    func testTheInstanceIsCheckedBeforeThePorts() {
        var f = Forward(id: 1)
        f.instance = ""
        f.localPort = "not-a-port"
        f.remotePort = "also-not"
        XCTAssertEqual(
            f.validate(), "Instance name is required.",
            "the first thing to fix should be reported first")
    }

    func testAWhitespaceOnlyInstanceIsMissing() {
        for value in [" ", "   ", "\t"] {
            var f = Forward(id: 1)
            f.instance = value
            f.localPort = "5432"
            f.remotePort = "5432"
            XCTAssertEqual(f.validate(), "Instance name is required.")
        }
    }

    func testTheLocalPortIsReportedBeforeTheRemoteOne() {
        var f = Forward(id: 1)
        f.instance = "db"
        f.localPort = "nope"
        f.remotePort = "also-nope"
        XCTAssertEqual(f.validate(), "Local port must be a number 1–65535.")
    }

    func testDecodingNormalisesAnUnreadableColourToNothing() throws {
        for bad in ["not-a-colour", "#12345", "#GGGGGG", "rgb(1,2,3)", "＃FF0000"] {
            let json = #"{"id":1,"instance":"db","color":"\#(bad)"}"#
            let f = try JSONDecoder().decode(Forward.self, from: Data(json.utf8))
            XCTAssertEqual(f.color, "", "\(bad) must be dropped, not kept as a broken value")
        }
    }

    func testDecodingExpandsAndUppercasesAShorthandColour() throws {
        let json = ##"{"id":1,"instance":"db","color":"#f0a"}"##
        let f = try JSONDecoder().decode(Forward.self, from: Data(json.utf8))
        XCTAssertEqual(f.color, "#FF00AA")
    }

    func testDecodingTrimsTheGroup() throws {
        let json = #"{"id":1,"instance":"db","group":"  databases  "}"#
        let f = try JSONDecoder().decode(Forward.self, from: Data(json.utf8))
        XCTAssertEqual(f.group, "databases", "a stray space would create a second identical-looking group")
    }

    func testDecodingAWhitespaceOnlyGroupLeavesItUngrouped() throws {
        let json = #"{"id":1,"instance":"db","group":"   "}"#
        let f = try JSONDecoder().decode(Forward.self, from: Data(json.utf8))
        XCTAssertEqual(f.group, "")
    }

    func testGroupIsCaseSensitiveAsAnIdentity() throws {
        let lower = try JSONDecoder().decode(
            Forward.self, from: Data(#"{"id":1,"instance":"db","group":"db"}"#.utf8))
        let upper = try JSONDecoder().decode(
            Forward.self, from: Data(#"{"id":2,"instance":"db","group":"DB"}"#.utf8))
        XCTAssertNotEqual(lower.group, upper.group, "merging these would undo a deliberate rename")
    }

    func testTargetAndRouteWithAnEmptyRemotePort() {
        var f = Forward(id: 1)
        f.localPort = "15432"
        XCTAssertEqual(f.target, "instance:")
        XCTAssertEqual(f.route, "15432 → instance:")
    }

    func testTitleUsesAWhitespaceNameAsGiven() {
        var f = Forward(id: 1)
        f.name = " "
        f.localPort = "1"
        f.remotePort = "2"
        XCTAssertEqual(f.title, " ", "the name is not trimmed by the model; the form trims on save")
    }

    func testEncodingOmitsNothingTheLoaderNeeds() throws {
        var f = Forward(id: 3)
        f.instance = "db"
        f.localPort = "1"
        f.remotePort = "2"
        let data = try JSONEncoder().encode(f)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["id", "name", "profile", "region", "instance", "localPort", "host", "remotePort", "color", "group"]
        {
            XCTAssertNotNil(object[key], "\(key) must survive a round trip through the store")
        }
    }

    func testEntryStateUptimeOnlyCountsWhileRunning() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let later = start.addingTimeInterval(125)
        for run in [RunState.stopped, .starting, .reconnecting, .stopping, .error] {
            var s = EntryState()
            s.run = run
            s.since = start
            XCTAssertNil(s.uptime(at: later), "\(run) is not uptime")
        }
        var running = EntryState()
        running.run = .running
        running.since = start
        XCTAssertEqual(running.uptime(at: later), "2m 5s")
    }

    func testEntryStateUptimeNeedsAStartStamp() {
        var s = EntryState()
        s.run = .running
        s.since = nil
        XCTAssertNil(s.uptime(at: Date()))
    }

    func testRunStatesAreAllDistinct() {
        let all: [RunState] = [.stopped, .starting, .running, .reconnecting, .stopping, .error]
        for (i, a) in all.enumerated() {
            for (j, b) in all.enumerated() where i != j {
                XCTAssertNotEqual(a, b, "\(a) and \(b) must not compare equal")
            }
        }
    }

    func testReconnectReasonsReadAsSentenceFragments() {
        XCTAssertEqual(ReconnectReason.sleep.rawValue, "after sleep")
        XCTAssertEqual(ReconnectReason.network.rawValue, "after a network change")
    }
}
