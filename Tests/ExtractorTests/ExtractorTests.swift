import Foundation
import Testing
@testable import Extractor

private func tile(_ cls: String, _ id: String?) -> Item {
    Item(cls: cls, box: [0, 0, 10, 10], area: 100, fillRgb: [0, 0, 0], legendRgb: [0, 0, 0],
         text: id ?? "", id: id, needsReview: false, reason: nil)
}

private func suggestions(_ ids: [String]) -> [String: String] {
    var items = ids.map { tile("INDONESIA", $0) }
    var counts: [String: Int] = [:]
    repairIdsByPrefix(&items, ruleCounts: &counts)
    return Dictionary(uniqueKeysWithValues: items.compactMap { item in item.suggestedId.map { (item.id ?? "", $0) } })
}

private func ring(size: Int, gapAt: Int? = nil) -> [Bool] {
    var mask = [Bool](repeating: false, count: size * size)
    for i in 0..<size {
        for (x, y) in [(i, 0), (i, size - 1), (0, i), (size - 1, i)] { mask[y * size + x] = true }
    }
    if let gapAt { mask[gapAt] = false }
    return mask
}

@Test func labelsAcceptUpToThreeLettersAndFoldCyrillic() {
    #expect(cleanLabel("FNB12") == "FNB12")
    #expect(cleanLabel(" gd 28 ") == "GD28")
    #expect(cleanLabel("\u{041C}30") == "M30")
    #expect(cleanLabel("A1B") == nil)
    #expect(cleanLabel("1234") == nil)
}

@Test func fillHolesFillsOnlyClosedSmallHoles() {
    let closed = fillHoles(ring(size: 7), w: 7, h: 7, maxHole: 30, seamLength: 20)
    #expect(closed[3 * 7 + 3])
    let leaking = fillHoles(ring(size: 7, gapAt: 3), w: 7, h: 7, maxHole: 30, seamLength: 20)
    #expect(!leaking[3 * 7 + 3])
    let tooBig = fillHoles(ring(size: 7), w: 7, h: 7, maxHole: 10, seamLength: 20)
    #expect(!tooBig[3 * 7 + 3])
}

@Test func zeroReadAsLetterOIsRepairedWhenTheShortPrefixIsCommon() {
    let common = (1...8).map { "N0\($0)" }
    let fixed = suggestions(common + ["NO9"])
    #expect(fixed["NO9"] == "N09")
}

@Test func confusablePrefixLetterNeedsAMuchCommonerNeighbour() {
    let many = (1...12).map { "GD\($0)" }
    #expect(suggestions(many + ["CD28"])["CD28"] == "GD28")
    // G is a real prefix here, only a rarer one, so it must not be rewritten to C.
    let mixed = (1...16).map { "C\($0)" } + (1...6).map { "G\($0)" }
    #expect(suggestions(mixed + ["G19"])["G19"] == nil)
}

@Test func duplicateIdSwapsOneDigitOnlyIntoAGap() {
    let series = (1...30).filter { $0 != 27 }.map { "E\(String(format: "%02d", $0))" }
    #expect(suggestions(series + ["E21"])["E21"] == "E27")
    // A truncated one-digit read is not the series width, so it gets no suggestion.
    #expect(suggestions(series + ["E2", "E2"])["E2"] == nil)
}

@Test func classPrefixNeedsAClearMajority() {
    let pure = (1...10).map { tile("Booth A", "A\($0)") }
    #expect(computeClassPrefixes(pure)["Booth A"] == "A")
    let mixed = (1...5).map { tile("INDONESIA", "A\($0)") } + (1...5).map { tile("INDONESIA", "B\($0)") }
    #expect(computeClassPrefixes(mixed)["INDONESIA"] == nil)
}

@Test func legendSwatchNeedsABoundedBlockOfOneColour() {
    let (w, h) = (60, 40)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    func paint(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
        let i = (y * w + x) * 4
        (rgba[i], rgba[i + 1], rgba[i + 2]) = c
    }
    for y in 10..<22 { for x in 10..<22 { paint(x, y, (220, 40, 40)) } }
    for x in 5..<55 { paint(x, 30, (0, 0, 0)) }
    let px = Pixels(width: w, height: h, rgba: rgba)
    #expect(isSwatch(px, seedX: 15, seedY: 15, textHeight: 12))
    #expect(!isSwatch(px, seedX: 30, seedY: 30, textHeight: 12))
    #expect(!isSwatch(px, seedX: 40, seedY: 15, textHeight: 12))
}
