import XCTest

@testable import AwssshApp

final class ReleaseNotesTests: XCTestCase {
    private let changelog = """
        # Changelog

        ## v1.0.0

        - Dismiss all errored forwards at once.

        ## v0.0.9

        - A bottom fade on the list marks that there is more below.

        ## v0.0.8

        - The menubar icon fits the menu bar.
        - The attention badge is sized to the glyph.
        """

    func testSectionsKeepFileOrderNewestFirst() {
        let sections = ReleaseNotes.parse(changelog)

        XCTAssertEqual(sections.map(\.version), ["1.0.0", "0.0.9", "0.0.8"])
        XCTAssertEqual(sections[2].entries.count, 2)
        XCTAssertEqual(sections[0].entries, ["Dismiss all errored forwards at once."])
    }

    func testTheTitleAndProseAreNotMistakenForVersions() {
        let sections = ReleaseNotes.parse(
            """
            # Changelog

            Some preamble that is not a bullet.

            ## Unreleased

            - should not be attributed to a version heading

            ## v0.1.0

            - real entry
            """)

        XCTAssertEqual(
            sections.map(\.version), ["0.1.0"],
            "a heading that is not a version must not become one")
        XCTAssertEqual(sections[0].entries, ["real entry"])
    }

    func testAVersionHeadingWithoutTheVPrefixStillCounts() {
        XCTAssertEqual(ReleaseNotes.parse("## 2.3.4\n\n- x").map(\.version), ["2.3.4"])
    }

    func testASectionWithNoBulletsIsDropped() {
        let sections = ReleaseNotes.parse("## v1.0.0\n\n## v0.9.0\n\n- only this one")

        XCTAssertEqual(sections.map(\.version), ["0.9.0"], "an empty section would render blank")
    }

    func testAnUpdateShowsEveryVersionCrossed() {
        let sections = ReleaseNotes.forUpdate(from: "0.0.8", to: "1.0.0", in: changelog)

        XCTAssertEqual(
            sections.map(\.version), ["1.0.0", "0.0.9"],
            "skipping a release must not skip its notes, and the version already seen is excluded")
    }

    func testAnUpdateNeverShowsNotesFromTheFuture() {
        let sections = ReleaseNotes.forUpdate(from: "0.0.8", to: "0.0.9", in: changelog)

        XCTAssertEqual(
            sections.map(\.version), ["0.0.9"],
            "a changelog committed ahead of the release must not leak unreleased notes")
    }

    func testNoNewVersionMeansNothingToShow() {
        XCTAssertTrue(ReleaseNotes.forUpdate(from: "1.0.0", to: "1.0.0", in: changelog).isEmpty)
        XCTAssertTrue(ReleaseNotes.forUpdate(from: "1.0.0", to: "0.0.9", in: changelog).isEmpty)
    }

    func testTheHistoryStopsAtTheRunningVersion() {
        XCTAssertEqual(
            ReleaseNotes.history(upTo: "0.0.9", in: changelog).map(\.version), ["0.0.9", "0.0.8"],
            "a changelog committed ahead of the release must not leak unreleased notes")
    }

    func testTheHistoryFallsBackToEverythingForABuildOlderThanEverySection() {
        XCTAssertEqual(
            ReleaseNotes.history(upTo: "0.0.0-dev", in: changelog).map(\.version),
            ["1.0.0", "0.0.9", "0.0.8"],
            "a dev build has no section of its own but must still render something")
    }

    func testAnEmptyChangelogYieldsNothingRatherThanCrashing() {
        XCTAssertTrue(ReleaseNotes.parse("").isEmpty)
        XCTAssertTrue(ReleaseNotes.history(upTo: "1.0.0", in: "").isEmpty)
        XCTAssertTrue(ReleaseNotes.forUpdate(from: "0.9.0", to: "1.0.0", in: "").isEmpty)
    }

    func testAnOverlongEntryIsCut() {
        let long = String(repeating: "x", count: ReleaseNotes.maxEntryLength + 50)
        let entries = ReleaseNotes.parse("## v1.0.0\n\n- \(long)")[0].entries

        XCTAssertEqual(entries[0].count, ReleaseNotes.maxEntryLength)
    }

    private func repoChangelog() -> String? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("CHANGELOG.md")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) { return text }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    func testTheShippedChangelogParses() {
        guard let text = repoChangelog() else { return }
        let sections = ReleaseNotes.parse(text)

        XCTAssertFalse(sections.isEmpty, "the real file has to parse, or the window is blank")
        XCTAssertTrue(
            sections.allSatisfy { !$0.entries.isEmpty },
            "every section kept must have something to show")
    }
}
