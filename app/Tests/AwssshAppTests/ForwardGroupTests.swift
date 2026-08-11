import XCTest

@testable import AwssshApp

final class ForwardGroupTests: XCTestCase {
    private func forward(_ id: Int, group: String = "", name: String = "") -> Forward {
        var f = Forward(id: id)
        f.name = name
        f.group = group
        f.instance = "db"
        f.localPort = "\(5000 + id)"
        f.remotePort = "5432"
        return f
    }

    func testForwardsAreBucketedByGroup() {
        let groups = ForwardGroup.build(from: [
            forward(1, group: "databases"),
            forward(2, group: "caches"),
            forward(3, group: "databases"),
        ])

        XCTAssertEqual(groups.map(\.name), ["caches", "databases"], "sorted by name")
        XCTAssertEqual(groups[1].forwards.map(\.id), [1, 3])
    }

    func testUngroupedForwardsComeLast() {
        let groups = ForwardGroup.build(from: [
            forward(1),
            forward(2, group: "databases"),
            forward(3),
        ])

        XCTAssertEqual(groups.map(\.name), ["databases", ""])
        XCTAssertEqual(groups[1].forwards.map(\.id), [1, 3])
    }

    func testOrderWithinAGroupIsTheSavedOrder() {
        let groups = ForwardGroup.build(from: [
            forward(3, group: "g"),
            forward(1, group: "g"),
            forward(2, group: "g"),
        ])
        XCTAssertEqual(groups[0].forwards.map(\.id), [3, 1, 2], "not re-sorted behind the user's back")
    }

    func testGroupNamesAreCaseInsensitivelySorted() {
        let groups = ForwardGroup.build(from: [
            forward(1, group: "zebra"),
            forward(2, group: "Apple"),
        ])
        XCTAssertEqual(groups.map(\.name), ["Apple", "zebra"])
    }

    func testGroupsAreCaseSensitiveAsIdentities() {
        let groups = ForwardGroup.build(from: [forward(1, group: "db"), forward(2, group: "DB")])
        XCTAssertEqual(groups.count, 2, "renaming the case is a real rename, not a merge")
    }

    func testNoForwardsMeansNoGroups() {
        XCTAssertTrue(ForwardGroup.build(from: []).isEmpty)
    }

    func testTheOnlyGroupBeingUngroupedIsTitledAllForwards() {
        let groups = ForwardGroup.build(from: [forward(1), forward(2)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(
            groups[0].title(soleGroup: true), "All forwards",
            "someone who never made a group should not be told their forwards are ungrouped")
    }

    func testUngroupedIsNamedOnceThereAreRealGroups() {
        let groups = ForwardGroup.build(from: [forward(1), forward(2, group: "databases")])
        XCTAssertEqual(groups[1].title(soleGroup: false), "Ungrouped")
        XCTAssertEqual(groups[0].title(soleGroup: false), "databases")
    }

    func testNamesListsEachGroupOnce() {
        let names = ForwardGroup.names(in: [
            forward(1, group: "databases"),
            forward(2, group: "caches"),
            forward(3, group: "databases"),
            forward(4),
        ])
        XCTAssertEqual(names, ["caches", "databases"], "no duplicates, no empty entry")
    }

    func testAStoredGroupIsTrimmed() throws {
        let data = Data(#"{"id":1,"instance":"db","group":"  databases  "}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Forward.self, from: data).group, "databases")
    }

    func testAMissingGroupDecodesToNone() throws {
        let f = try JSONDecoder().decode(Forward.self, from: Data(#"{"id":1}"#.utf8))
        XCTAssertEqual(f.group, "")
    }

    func testTheTemporaryGroupSortsBeforeEverythingElse() {
        let groups = ForwardGroup.build(from: [
            forward(1, group: "alpha"),
            forward(2, group: ForwardGroup.temporaryName),
            forward(3, group: "beta"),
            forward(4),
        ])
        XCTAssertEqual(
            groups.map(\.name), [ForwardGroup.temporaryName, "alpha", "beta", ""],
            "what you just started belongs at the top, ungrouped stays at the bottom")
        XCTAssertTrue(groups[0].isTemporary)
        XCTAssertFalse(groups[1].isTemporary)
    }

    func testTheTemporaryGroupIsNotOfferedAsASavedGroupName() {
        let names = ForwardGroup.names(in: [forward(1, group: "alpha")])
        XCTAssertEqual(names, ["alpha"], "the picker lists saved groups, and it is built from those")
    }

    func testTheGroupSurvivesACodableRoundTrip() throws {
        var f = forward(1, group: "databases")
        f.color = "#FF453A"

        let data = try JSONEncoder().encode(f)
        XCTAssertEqual(try JSONDecoder().decode(Forward.self, from: data), f)
    }
}
