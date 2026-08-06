import XCTest

@testable import AwssshApp

final class HelperProtocolTests: XCTestCase {
    private func encode(_ command: HelperCommand) throws -> [String: Any] {
        let data = try JSONEncoder().encode(command)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ json: String) throws -> HelperMessage {
        try JSONDecoder().decode(HelperMessage.self, from: Data(json.utf8))
    }

    func testAStartCommandCarriesTheKeysTheHelperDeclares() throws {
        let command = HelperCommand(
            cmd: "start",
            id: 7,
            forward: HelperForward(
                profile: "dev",
                region: "eu-west-1",
                instance: "i-0abc",
                local: "15432",
                host: "db.internal",
                remote: "5432"
            )
        )
        let object = try encode(command)
        XCTAssertEqual(object["cmd"] as? String, "start")
        XCTAssertEqual(object["id"] as? Int, 7)

        let forward = try XCTUnwrap(object["forward"] as? [String: Any])
        XCTAssertEqual(forward["profile"] as? String, "dev")
        XCTAssertEqual(forward["region"] as? String, "eu-west-1")
        XCTAssertEqual(forward["instance"] as? String, "i-0abc")
        XCTAssertEqual(forward["host"] as? String, "db.internal")
    }

    func testThePortKeysAreLocalAndRemoteNotLocalPortAndRemotePort() throws {
        let command = HelperCommand(
            cmd: "start",
            id: 1,
            forward: HelperForward(
                profile: "",
                region: "",
                instance: "db",
                local: "15432",
                host: "",
                remote: "5432"
            )
        )
        let forward = try XCTUnwrap(try encode(command)["forward"] as? [String: Any])

        XCTAssertEqual(
            forward["local"] as? String, "15432",
            "the Go helper's forwardSpec tags these `local` and `remote`; renaming the Swift "
                + "properties silently breaks every start")
        XCTAssertEqual(forward["remote"] as? String, "5432")
        XCTAssertNil(forward["localPort"], "localPort is the Forward model's name, not the wire's")
        XCTAssertNil(forward["remotePort"])
    }

    func testTheForwardSpecHasExactlySixKeys() throws {
        let command = HelperCommand(
            cmd: "start",
            id: 1,
            forward: HelperForward(
                profile: "p", region: "r", instance: "i", local: "1", host: "h", remote: "2")
        )
        let forward = try XCTUnwrap(try encode(command)["forward"] as? [String: Any])
        XCTAssertEqual(
            Set(forward.keys), ["profile", "region", "instance", "local", "host", "remote"],
            "an extra or missing key here is a protocol change")
    }

    func testASimpleCommandOmitsTheForwardEntirely() throws {
        for name in ["profiles", "logins", "stopAll"] {
            let object = try encode(HelperCommand(cmd: name))
            XCTAssertEqual(object["cmd"] as? String, name)
            XCTAssertNil(object["forward"], "\(name) must not carry a forward")
            XCTAssertNil(object["login"], "\(name) must not carry a login")
        }
    }

    func testAStopCommandCarriesOnlyTheID() throws {
        let object = try encode(HelperCommand(cmd: "stop", id: 3))
        XCTAssertEqual(object["cmd"] as? String, "stop")
        XCTAssertEqual(object["id"] as? Int, 3)
        XCTAssertNil(object["forward"])
    }

    func testLoginCommandsCarryTheLabel() throws {
        for name in ["ssoLogin", "checkLogin"] {
            let object = try encode(HelperCommand(cmd: name, login: "company"))
            XCTAssertEqual(object["cmd"] as? String, name)
            XCTAssertEqual(object["login"] as? String, "company")
        }
    }

    func testCommandEncodesToASingleLineSoTheHelperCanReadItPerLine() throws {
        let command = HelperCommand(
            cmd: "start",
            id: 1,
            forward: HelperForward(
                profile: "p", region: "r", instance: "i", local: "1", host: "h", remote: "2")
        )
        let data = try JSONEncoder().encode(command)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("\n"), "the helper reads one JSON object per line")
    }

    func testStartedMessageDecodes() throws {
        let message = try decode(#"{"event":"started","id":4,"detail":"localhost:15432"}"#)
        XCTAssertEqual(message.event, "started")
        XCTAssertEqual(message.id, 4)
        XCTAssertEqual(message.detail, "localhost:15432")
        XCTAssertNil(message.error)
    }

    func testExitedMessageWithAReasonDecodes() throws {
        let message = try decode(#"{"event":"exited","id":4,"error":"the session ended on its own"}"#)
        XCTAssertEqual(message.event, "exited")
        XCTAssertEqual(message.error, "the session ended on its own")
    }

    func testABareExitedMessageDecodes() throws {
        let message = try decode(#"{"event":"exited","id":4}"#)
        XCTAssertEqual(message.event, "exited")
        XCTAssertNil(message.error, "a stop the user asked for carries no error")
        XCTAssertNil(message.detail)
    }

    func testProfilesMessageDecodes() throws {
        let message = try decode(#"{"event":"profiles","profiles":["default","dev","prod"]}"#)
        XCTAssertEqual(message.profiles, ["default", "dev", "prod"])
    }

    func testAnEmptyProfileListDecodesAsEmptyNotNil() throws {
        let message = try decode(#"{"event":"profiles","profiles":[]}"#)
        XCTAssertEqual(message.profiles, [])
    }

    func testLoginsMessageDecodesEveryField() throws {
        let json = """
            {"event":"logins","logins":[
              {"label":"company","profiles":["dev","prod"],"expires":"2026-07-31T12:00:00Z","refreshable":true},
              {"label":"other","profiles":["staging"]}
            ]}
            """
        let message = try decode(json)
        let logins = try XCTUnwrap(message.logins)
        XCTAssertEqual(logins.count, 2)
        XCTAssertEqual(logins[0].label, "company")
        XCTAssertEqual(logins[0].profiles, ["dev", "prod"])
        XCTAssertEqual(logins[0].expires, "2026-07-31T12:00:00Z")
        XCTAssertEqual(logins[0].refreshable, true)

        XCTAssertEqual(logins[1].label, "other")
        XCTAssertNil(logins[1].expires, "the Go side omits an empty expiry")
        XCTAssertNil(logins[1].refreshable, "the Go side omits a false refreshable")
    }

    func testCheckLoginMessageDecodesTheState() throws {
        for state in ["valid", "expired", "unknown"] {
            let message = try decode(#"{"event":"checkLogin","detail":"company","state":"\#(state)"}"#)
            XCTAssertEqual(message.state, state)
            XCTAssertEqual(message.detail, "company")
        }
    }

    func testReadyMessageDecodes() throws {
        let message = try decode(#"{"event":"ready"}"#)
        XCTAssertEqual(message.event, "ready")
        XCTAssertNil(message.id)
    }

    func testAnUnknownEventStillDecodesRatherThanKillingTheStream() throws {
        let message = try decode(#"{"event":"somethingNew","id":1}"#)
        XCTAssertEqual(message.event, "somethingNew")
    }

    func testUnknownFieldsAreIgnored() throws {
        let message = try decode(#"{"event":"started","id":1,"somethingAdded":true,"nested":{"a":1}}"#)
        XCTAssertEqual(message.event, "started")
        XCTAssertEqual(message.id, 1)
    }

    func testAMessageWithoutAnEventIsRejected() {
        XCTAssertThrowsError(try decode(#"{"id":1}"#)) { _ in }
    }

    func testMalformedJSONIsRejectedRatherThanSilentlyEmpty() {
        for bad in ["", "not json", "[]", "{", #"{"event":}"#] {
            XCTAssertThrowsError(try decode(bad), "\(bad) must not decode") { _ in }
        }
    }

    func testAWronglyTypedIDIsRejected() {
        XCTAssertThrowsError(try decode(#"{"event":"started","id":"four"}"#)) { _ in }
    }

    func testEveryCommandTheModelSendsRoundTripsThroughJSON() throws {
        let commands = [
            HelperCommand(cmd: "profiles"),
            HelperCommand(cmd: "logins"),
            HelperCommand(cmd: "stopAll"),
            HelperCommand(cmd: "stop", id: 2),
            HelperCommand(cmd: "ssoLogin", login: "company"),
            HelperCommand(cmd: "checkLogin", login: "company"),
            HelperCommand(
                cmd: "start",
                id: 9,
                forward: HelperForward(
                    profile: "dev", region: "eu-west-1", instance: "i-0abc",
                    local: "15432", host: "db.internal", remote: "5432")),
        ]
        for command in commands {
            let data = try JSONEncoder().encode(command)
            let back = try JSONDecoder().decode(HelperCommand.self, from: data)
            XCTAssertEqual(back.cmd, command.cmd)
            XCTAssertEqual(back.id, command.id)
            XCTAssertEqual(back.login, command.login)
            XCTAssertEqual(back.forward?.local, command.forward?.local)
            XCTAssertEqual(back.forward?.remote, command.forward?.remote)
            XCTAssertEqual(back.forward?.instance, command.forward?.instance)
        }
    }

    func testAForwardSpecSurvivesAwkwardButLegalValues() throws {
        let command = HelperCommand(
            cmd: "start",
            id: 1,
            forward: HelperForward(
                profile: "prof \"quoted\"",
                region: "eu-west-1",
                instance: "name with spaces & symbols",
                local: "15432",
                host: "hôst.internal",
                remote: "5432")
        )
        let data = try JSONEncoder().encode(command)
        let back = try JSONDecoder().decode(HelperCommand.self, from: data)
        XCTAssertEqual(back.forward?.profile, "prof \"quoted\"")
        XCTAssertEqual(back.forward?.instance, "name with spaces & symbols")
        XCTAssertEqual(back.forward?.host, "hôst.internal")
    }

    func testASignInCommandCarriesOnlyTheLogin() throws {
        let object = try encode(HelperCommand(cmd: "ssoLogin", login: "company"))

        XCTAssertEqual(object["cmd"] as? String, "ssoLogin")
        XCTAssertEqual(object["login"] as? String, "company")
        XCTAssertNil(
            object["background"], "the browser modes are gone; the helper only knows one way in")
        XCTAssertNil(object["embedded"])
    }

    func testAnAuthorizeURLMessageCarriesTheURL() throws {
        let message = try decode(
            #"{"event":"authorizeURL","detail":"company","url":"https://oidc.example/authorize?x=1"}"#)

        XCTAssertEqual(message.event, "authorizeURL")
        XCTAssertEqual(message.detail, "company")
        XCTAssertEqual(message.url, "https://oidc.example/authorize?x=1")
    }

    func testALoginSaysWhetherItsSessionCanRenew() throws {
        let message = try decode(
            """
            {"event":"logins","logins":[{"label":"company","profiles":["dev"],\
            "refreshable":true,"scoped":true}]}
            """)

        let login = try XCTUnwrap(message.logins?.first)
        XCTAssertEqual(login.refreshable, true)
        XCTAssertEqual(login.scoped, true)
    }

    func testAnOlderHelperWithoutScopedStillDecodes() throws {
        let message = try decode(
            #"{"event":"logins","logins":[{"label":"company","profiles":["dev"]}]}"#)

        let login = try XCTUnwrap(message.logins?.first)
        XCTAssertNil(login.scoped)
        XCTAssertFalse(SSOLogin(login).scoped)
    }

    func testAPendingSignInNamesTheLoginItIsWaitingOn() throws {
        let message = try decode(#"{"event":"ssoLoginPending","detail":"company"}"#)

        XCTAssertEqual(message.event, "ssoLoginPending")
        XCTAssertEqual(message.detail, "company")
    }
}
