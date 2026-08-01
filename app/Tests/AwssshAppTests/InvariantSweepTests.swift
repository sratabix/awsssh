import AppKit
import Carbon.HIToolbox
import XCTest

@testable import AwssshApp

final class InvariantSweepTests: XCTestCase {
    private func inputs(seed: UInt64 = 0x9E37_79B9_7F4A_7C15, count: Int = 4_000) -> [String] {
        var state = seed
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }

        let alphabet = Array(
            "0123456789abcdefABCDEF#gGzZ -\t\n\u{0}\u{202E}\u{200E}０１２３４５６７８９ａｆＦ日本語🎉ünï")
        var out: [String] = [
            "", " ", "#", "##", "#f", "#ff", "#fff", "#ffff", "#ffffff", "#fffffff",
            "fff", "ffffff", "FFFFFF", "  #fff  ", "#GGG", "0x0", "＃FFFFFF",
        ]
        for _ in 0..<count {
            let length = Int(next() % 10)
            var s = ""
            for _ in 0..<length {
                s.append(alphabet[Int(next() % UInt64(alphabet.count))])
            }
            out.append(s)
        }
        return out
    }

    func testANormalisedColourIsAlwaysOneThatRenders() {
        for raw in inputs() {
            let normalised = ForwardColor.normalise(raw)
            guard !normalised.isEmpty else {
                XCTAssertNil(
                    ForwardColor.color(raw),
                    "\(raw.debugDescription) normalised to nothing, so it must not render either")
                continue
            }
            XCTAssertNotNil(
                ForwardColor.color(raw),
                "\(raw.debugDescription) normalised to \(normalised) but produced no colour — "
                    + "that is the fullwidth-digit mismatch the hex set exists to prevent")
        }
    }

    func testNormaliseIsIdempotentAndWellShaped() {
        for raw in inputs() {
            let once = ForwardColor.normalise(raw)
            XCTAssertEqual(
                ForwardColor.normalise(once), once,
                "normalising \(raw.debugDescription) twice differed from once")
            guard !once.isEmpty else { continue }
            XCTAssertEqual(once.count, 7, "\(once) must be # plus six digits")
            XCTAssertTrue(once.hasPrefix("#"))
            XCTAssertEqual(once, once.uppercased())
            XCTAssertNotNil(UInt32(once.dropFirst(), radix: 16), "\(once) must parse as hex")
        }
    }

    func testCleanAlwaysProducesAStorableField() {
        for raw in inputs() {
            let cleaned = Share.clean(raw)
            XCTAssertLessThanOrEqual(cleaned.count, Share.maxFieldLength)
            XCTAssertEqual(
                cleaned, cleaned.trimmingCharacters(in: .whitespaces),
                "\(raw.debugDescription) cleaned to something still padded")
            for scalar in cleaned.unicodeScalars {
                XCTAssertFalse(
                    CharacterSet.controlCharacters.contains(scalar),
                    "\(raw.debugDescription) kept control U+\(String(scalar.value, radix: 16))")
            }
            XCTAssertEqual(Share.clean(cleaned), cleaned, "clean must be idempotent")
        }
    }

    func testDecodingArbitraryTextNeverCrashesAndEitherThrowsOrValidates() {
        for raw in inputs() {
            if let payload = try? Share.decode(raw) {
                XCTAssertFalse(
                    payload.instance.isEmpty,
                    "\(raw.debugDescription) decoded with no instance; that is the only guard "
                        + "stopping any JSON from being accepted")
            }
        }
    }

    func testStoreDecodeSurvivesArbitraryBytes() {
        for raw in inputs() {
            let result = Store.decode(Data(raw.utf8))
            for forward in result.forwards {
                XCTAssertGreaterThan(forward.id, 0, "sanitise must reassign non-positive ids")
                XCTAssertEqual(forward.color, ForwardColor.normalise(forward.color))
                XCTAssertEqual(forward.group, forward.group.trimmingCharacters(in: .whitespaces))
            }
            let ids = result.forwards.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "ids must be unique after sanitise")
        }
    }

    func testEveryKeyCodeProducesANonEmptyShortcutLabel() {
        let combos: [UInt32] = [
            UInt32(cmdKey),
            UInt32(controlKey),
            UInt32(optionKey),
            UInt32(cmdKey) | UInt32(shiftKey),
            UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey) | UInt32(shiftKey),
        ]
        var built = 0
        for code in UInt32(0)...127 {
            for modifiers in combos {
                guard let key = HotKey(keyCode: code, carbonModifiers: modifiers) else { continue }
                built += 1
                let label = key.displayString
                XCTAssertFalse(label.isEmpty, "key code \(code) rendered an empty label")
                XCTAssertFalse(
                    label.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
                    "key code \(code) rendered a control character: \(label.debugDescription)")
            }
        }
        XCTAssertGreaterThan(built, 500, "the sweep must actually build shortcuts, not skip them all")
    }

    func testShiftAloneNeverBuildsAShortcutAtAnyKeyCode() {
        for code in UInt32(0)...127 {
            XCTAssertNil(
                HotKey(keyCode: code, carbonModifiers: UInt32(shiftKey)),
                "shift plus \(code) would grab a plain typed key in every app")
            XCTAssertNil(HotKey(keyCode: code, carbonModifiers: 0))
        }
    }

    func testEveryBuiltShortcutSurvivesACodableRoundTrip() throws {
        for code in UInt32(0)...127 {
            guard let key = HotKey(keyCode: code, carbonModifiers: UInt32(cmdKey)) else { continue }
            let data = try JSONEncoder().encode(key)
            let back = try JSONDecoder().decode(HotKey.self, from: data)
            XCTAssertEqual(back, key, "key code \(code) did not round trip")
        }
    }

    func testUptimeLabelIsNeverEmptyOrNegative() {
        var seconds: TimeInterval = -100
        while seconds < 200_000 {
            let label = EntryState.uptimeLabel(seconds)
            XCTAssertFalse(label.isEmpty, "\(seconds) produced no label")
            XCTAssertFalse(label.contains("-"), "\(seconds) produced \(label)")
            seconds += 997.5
        }
    }

    func testRemainingIsNeverEmptyOrNegative() {
        var seconds: TimeInterval = -100
        while seconds < 200_000 {
            let label = SSOLogin.remaining(seconds)
            XCTAssertFalse(label.isEmpty, "\(seconds) produced no label")
            XCTAssertFalse(label.contains("-"), "\(seconds) produced \(label)")
            seconds += 997.5
        }
    }

    func testVersionComparisonIsAntisymmetricAndIrreflexive() {
        let versions = [
            "0", "0.0", "0.0.1", "0.0.9", "0.0.10", "0.1", "0.1.0", "0.2.0",
            "1.0.0", "1.0.1", "1.9.9", "1.10.0", "2.0.0", "10.0.0",
            "1.0.0-dev", "1.0.0-rc1", "", "v1", "abc",
        ]
        for a in versions {
            XCTAssertFalse(
                UpdateChecker.isNewer(remote: a, current: a),
                "\(a) must not be newer than itself")
            for b in versions where a != b {
                let forward = UpdateChecker.isNewer(remote: a, current: b)
                let backward = UpdateChecker.isNewer(remote: b, current: a)
                XCTAssertFalse(
                    forward && backward,
                    "\(a) and \(b) cannot each be newer than the other")
            }
        }
    }

    func testVersionComparisonIsTransitive() {
        let ordered = ["0.0.1", "0.0.9", "0.0.10", "0.1.0", "1.0.0", "1.0.1", "1.10.0", "2.0.0"]
        for i in ordered.indices {
            for j in ordered.indices where j > i {
                XCTAssertTrue(
                    UpdateChecker.isNewer(remote: ordered[j], current: ordered[i]),
                    "\(ordered[j]) must be newer than \(ordered[i])")
                XCTAssertFalse(
                    UpdateChecker.isNewer(remote: ordered[i], current: ordered[j]),
                    "\(ordered[i]) must not be newer than \(ordered[j])")
            }
        }
    }

    func testParseReleaseNeverCrashesOnArbitraryJSONShapes() {
        let shapes = [
            "{}", "[]", "null", "0", #"{"tag_name":null}"#, #"{"tag_name":{}}"#,
            #"{"tag_name":"v1","assets":null}"#, #"{"tag_name":"v1","assets":{}}"#,
            #"{"tag_name":"v1","assets":[null]}"#, #"{"tag_name":"v1","assets":[{}]}"#,
            #"{"tag_name":"v1","assets":[{"name":"Awsssh-1.zip"}]}"#,
            #"{"tag_name":"v1","prerelease":"yes"}"#,
            #"{"tag_name":"v1","html_url":42}"#,
        ]
        for shape in shapes {
            let release = UpdateChecker.parseRelease(Data(shape.utf8))
            guard let release else { continue }
            if let asset = release.asset {
                XCTAssertEqual(asset.sha256.count, 64, "\(shape) produced a malformed digest")
                XCTAssertTrue(Installer.isTrustedDownload(asset.url))
            }
        }
    }

    func testUnsafeEntryNeverAcceptsAnythingEscapingTheDirectory() {
        let dangerous = [
            "/abs", "../up", "a/../../b", "a/..", "..", "../", "/", "//etc/passwd",
            "Awsssh.app/../../../../etc/passwd",
        ]
        for entry in dangerous {
            XCTAssertNotNil(
                Installer.unsafeEntry(in: [entry]), "\(entry) must be refused before extraction")
        }

        let safe = [
            "Awsssh.app/", "Awsssh.app/Contents/Info.plist", "./Awsssh.app/x",
            "Awsssh.app/Contents/..name", "Awsssh.app/a..b",
        ]
        for entry in safe {
            XCTAssertNil(Installer.unsafeEntry(in: [entry]), "\(entry) is legitimate")
        }
    }
}
