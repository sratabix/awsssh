import XCTest

@testable import AwssshApp

final class ShareCleanTests: XCTestCase {
    private static let deceptive: [UInt32] = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]

    func testCleanStripsEveryDeceptiveDirectionScalar() {
        for value in Self.deceptive {
            let scalar = Unicode.Scalar(value)!
            let cleaned = Share.clean("db" + String(scalar) + "internal")
            XCTAssertEqual(
                cleaned, "dbinternal",
                "U+\(String(value, radix: 16, uppercase: true)) must not survive; it makes a name "
                    + "render as something other than what will be connected to")
        }
    }

    func testCleanStripsADeceptiveScalarWhereverItSits() {
        let rtl = String(Unicode.Scalar(0x202E)!)
        XCTAssertEqual(Share.clean(rtl + "leading"), "leading")
        XCTAssertEqual(Share.clean("trailing" + rtl), "trailing")
        XCTAssertEqual(Share.clean("mid" + rtl + "dle"), "middle")
        XCTAssertEqual(Share.clean(rtl + rtl + rtl), "")
    }

    func testCleanStripsControlCharactersIncludingNUL() {
        for value: UInt32 in [0x00, 0x01, 0x07, 0x1B, 0x7F] {
            let scalar = Unicode.Scalar(value)!
            XCTAssertEqual(
                Share.clean("a" + String(scalar) + "b"), "ab",
                "control U+\(String(value, radix: 16, uppercase: true)) must be dropped")
        }
    }

    func testCleanStripsNewlinesAndTabsFromInsideAField() {
        XCTAssertEqual(Share.clean("line\nbreak"), "linebreak")
        XCTAssertEqual(Share.clean("tab\tseparated"), "tabseparated")
        XCTAssertEqual(Share.clean("carriage\rreturn"), "carriagereturn")
        XCTAssertEqual(Share.clean("a\r\nb"), "ab")
    }

    func testCleanCapsAtExactlyTheLimit() {
        let long = String(repeating: "a", count: Share.maxFieldLength + 50)
        XCTAssertEqual(Share.clean(long).count, Share.maxFieldLength)

        let exact = String(repeating: "b", count: Share.maxFieldLength)
        XCTAssertEqual(Share.clean(exact), exact, "a field exactly at the limit must be untouched")

        let under = String(repeating: "c", count: Share.maxFieldLength - 1)
        XCTAssertEqual(Share.clean(under).count, Share.maxFieldLength - 1)
    }

    func testCleanTrimsBeforeItCapsSoPaddingCannotEatTheLimit() {
        let padded = "   " + String(repeating: "a", count: 10) + "   "
        XCTAssertEqual(Share.clean(padded), String(repeating: "a", count: 10))
    }

    func testCleanKeepsLegitimateNonASCII() {
        for value in ["db-münchen", "café-prod", "naïve", "Ωmega"] {
            XCTAssertEqual(Share.clean(value), value, "\(value) is a legitimate name")
        }
    }

    func testCleanOnAnEmptyOrWhitespaceOnlyStringIsEmpty() {
        let marker = String(Unicode.Scalar(0x200E)!)
        for value in ["", " ", "   ", "\n", "\t", marker] {
            XCTAssertEqual(
                Share.clean(value), "", "\(value.debugDescription) must clean to nothing")
        }
    }

    func testCleanIsIdempotent() {
        let rtl = String(Unicode.Scalar(0x202E)!)
        for value in ["  db" + rtl + "name  ", String(repeating: "x", count: 300), "plain"] {
            let once = Share.clean(value)
            XCTAssertEqual(
                Share.clean(once), once, "cleaning twice must not differ from cleaning once")
        }
    }

    func testAnImportedInstanceIsCleanedNotJustValidated() throws {
        let rtl = String(Unicode.Scalar(0x202E)!)
        let json = """
            {"instance":"  i-0abc\(rtl)def  ","localPort":"5432"}
            """
        let payload = try Share.decode(json)
        XCTAssertEqual(payload.instance, "i-0abcdef")
    }

    func testEveryTextFieldOfAPastedPayloadIsCleaned() throws {
        let rtl = String(Unicode.Scalar(0x202E)!)
        let json = """
            {"name":" n\(rtl)a ","profile":" p\(rtl)b ","region":" r\(rtl)c ",
             "instance":" i\(rtl)d ","localPort":" 1\(rtl)5432 ","host":" h\(rtl)e ",
             "remotePort":" 5\(rtl)432 ","group":" g\(rtl)f "}
            """
        let payload = try Share.decode(json)

        XCTAssertEqual(payload.name, "na")
        XCTAssertEqual(payload.profile, "pb")
        XCTAssertEqual(payload.region, "rc")
        XCTAssertEqual(payload.instance, "id")
        XCTAssertEqual(payload.localPort, "15432")
        XCTAssertEqual(payload.host, "he")
        XCTAssertEqual(payload.remotePort, "5432")
        XCTAssertEqual(payload.group, "gf")
    }

    func testAnOverlongPastedFieldIsCappedNotRejected() throws {
        let huge = String(repeating: "n", count: 5_000)
        let json = """
            {"instance":"db","localPort":"5432","name":"\(huge)"}
            """
        let payload = try Share.decode(json)
        XCTAssertEqual(payload.name.count, Share.maxFieldLength)
        XCTAssertEqual(payload.instance, "db", "the rest of the payload must still arrive")
    }

    func testSharedTextOfAForwardWithNastyFieldsStillReimportsCleanly() throws {
        let rtl = String(Unicode.Scalar(0x202E)!)
        var forward = Forward(id: 1)
        forward.name = "prod" + rtl + "db"
        forward.instance = "i-0abc"
        forward.localPort = "15432"
        forward.remotePort = "5432"
        forward.group = "  databases  "

        let payload = try Share.decode(Share.encode(forward))
        XCTAssertEqual(payload.name, "proddb")
        XCTAssertEqual(payload.group, "databases")
    }
}
