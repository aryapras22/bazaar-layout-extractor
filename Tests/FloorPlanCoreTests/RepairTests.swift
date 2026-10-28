import Foundation
import Testing
@testable import FloorPlanCore

private func load(_ name: String) throws -> Layout {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Layout.self, from: Data(contentsOf: url))
}

private func repaired(_ name: String) throws -> RepairResult {
    let layout = try load(name)
    return repair(layout.items, image: (layout.image.width, layout.image.height))
}

private func unlabeled(_ items: [LayoutItem], in cls: String) -> [LayoutItem] {
    items.filter { $0.cls == cls && $0.id == nil }
}

@Test func plan1UnlabeledTilesTakeTheOneGap() throws {
    let items = try repaired("plan1").items
    #expect(unlabeled(items, in: "Booth H").map(\.suggestedId) == ["H3"])
    #expect(unlabeled(items, in: "Booth G").map(\.suggestedId) == ["G11"])
    #expect(unlabeled(items, in: "Large booth X").map(\.suggestedId) == ["X1"])
}

@Test func plan1PrefixConflictBecomesTheClassPrefixAndKeepsTheOriginalId() throws {
    let items = try repaired("plan1").items
    let tile = try #require(items.first { $0.cls == "Booth C" && $0.id == "D6" })
    #expect(tile.suggestedId == "C6")
    #expect(tile.needsReview)
    #expect(items.first { $0.cls == "Booth D" && $0.id == "D6" }?.suggestedId == nil)
}

@Test func plan1DoorprizeGetsNoSuggestion() throws {
    let items = try repaired("plan1").items
    let tile = try #require(items.first { $0.text == "DOORPRIZE" })
    #expect(tile.suggestedId == nil)
}

@Test func plan2OcrConfusionsLandOnGaps() throws {
    let items = try repaired("plan2").items
    #expect(items.first { $0.text == "FI" }?.suggestedId == "F1")
    #expect(items.first { $0.text == "FZ" }?.suggestedId == "F7")
    #expect(items.first { $0.text == "EI" }?.suggestedId == "I3")
}

@Test func plan2PrefixlessIdIsFlaggedThenCompleted() throws {
    let layout = try load("plan2")
    let flagged = idPatternIssues(layout.items).map { layout.items[$0.index].id }
    #expect(flagged == ["19"])
    let tile = try #require(try repaired("plan2").items.first { $0.id == "19" })
    #expect(tile.suggestedId == "I9")
}

@Test func plan2UnlabeledShapesOnAWrappingClassAreOrderedByNeighbours() throws {
    let shapes = unlabeled(try repaired("plan2").items, in: "Booth C").sorted { $0.box[1] < $1.box[1] }
    #expect(shapes.map(\.suggestedId) == ["C6", "C2"])
    #expect(shapes.map { $0.box[1] }.allSatisfy { [1079, 1441].contains($0) })
}

@Test func plan1ModularObjectsMergeIntoOneGroup() throws {
    let items = try load("plan1").items
    func index(_ a: Int, _ b: Int) throws -> Int {
        try #require(items.indices.first { items[$0].cls == "object" && Set([items[$0].box[2], items[$0].box[3]]) == Set([a, b]) })
    }
    let square = try index(48, 48), double = try index(48, 100), triple = try index(48, 153)
    let group = try #require(moduleGroups(items).first { $0.contains(square) })
    #expect(group.contains(double))
    #expect(group.contains(triple))
}

@Test func plan1ThinRunsBetweenThickWallPiecesBecomeDoors() throws {
    let doors = try repaired("plan1").items.filter { $0.cls == "door" }
    #expect(doors.count == 4)
    #expect(doors.allSatisfy { $0.source == "thickness-transition" && $0.box[1] == 70 })
}

@Test func unequalCandidateAndGapCountsProduceNoSuggestion() {
    func tile(_ id: String?, _ x: Int) -> LayoutItem { LayoutItem(cls: "Booth Q", box: [x, 0, 50, 50], id: id) }
    let oneGapTwoCandidates = [tile("Q1", 0), tile("Q2", 60), tile("Q4", 120), tile(nil, 180), tile(nil, 240)]
    #expect(repair(oneGapTwoCandidates, image: (1000, 1000)).items.allSatisfy { $0.suggestedId == nil })
    let twoGapsOneCandidate = [tile("Q1", 0), tile("Q4", 60), tile("Q5", 120), tile(nil, 180)]
    #expect(repair(twoGapsOneCandidate, image: (1000, 1000)).items.allSatisfy { $0.suggestedId == nil })
}
