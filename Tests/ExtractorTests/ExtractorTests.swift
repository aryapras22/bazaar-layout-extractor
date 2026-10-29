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

private func gridWithTiles(side: Int, count: Int, page: Int) -> [Int16] {
    var grid = [Int16](repeating: -1, count: page * page)
    for t in 0..<count {
        let x0 = 20 + (t % 10) * (side + 20), y0 = 20 + (t / 10) * (side + 20)
        for y in y0..<(y0 + side) { for x in x0..<(x0 + side) { grid[y * page + x] = 0 } }
    }
    return grid
}

@Test func tileScaleShrinksForSmallTilesAndNeverPassesThePageScale() {
    let small = gridWithTiles(side: 24, count: 20, page: 3000)
    #expect(abs(tileScale(small, w: 3000, h: 3000, page: 3000, area: 9000000) - 24.0 / referenceTileSide) < 0.01)
    let large = gridWithTiles(side: 100, count: 20, page: 2000)
    #expect(tileScale(large, w: 2000, h: 2000, page: 2000, area: 4000000) == 1.0)
    let few = gridWithTiles(side: 24, count: 3, page: 3000)
    #expect(tileScale(few, w: 3000, h: 3000, page: 3000, area: 9000000) == 1.5)
}

@Test func contentExtentIgnoresMarginsAndSpecks() {
    let (w, h) = (100, 80)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    func paint(_ x: Int, _ y: Int) {
        let i = (y * w + x) * 4
        (rgba[i], rgba[i + 1], rgba[i + 2]) = (0, 0, 0)
    }
    for y in 40..<50 { for x in 30..<50 { paint(x, y) } }
    paint(95, 5)  // a lone speck must not stretch the box
    let extent = contentExtent(rgba, width: w, height: h)
    #expect(extent.side == 20)
    #expect(extent.area == 200)
    #expect(extent.rect == CGRect(x: 30, y: 40, width: 20, height: 10))
}

private func planWithBlocks(limeSide: Int) -> Pixels {
    let (w, h) = (400, 400)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    func fill(_ x0: Int, _ y0: Int, _ side: Int, _ c: (UInt8, UInt8, UInt8)) {
        for y in y0..<(y0 + side) { for x in x0..<(x0 + side) { let i = (y * w + x) * 4; (rgba[i], rgba[i + 1], rgba[i + 2]) = c } }
    }
    fill(20, 20, 200, (120, 184, 80))   // the plan's own green
    fill(250, 250, limeSide, (196, 214, 82))  // the legend lime, e.g. the swatch printed inside the plan
    return Pixels(width: w, height: h, rgba: rgba)
}

@Test func legendColourMovesToADominantPlanColourOnlyWhenItClearlyOutweighsTheMatch() {
    let lime = LegendClass(name: "GOODS", rgb: (196, 214, 82), lab: lab((196, 214, 82)))
    let moved = adaptLegendToPlan([lime], planWithBlocks(limeSide: 15), classes: [0])
    #expect(moved[0].rgb == (120, 184, 80))
    // A class that already matches a block over a quarter of the green one's size keeps its own colour.
    let kept = adaptLegendToPlan([lime], planWithBlocks(limeSide: 110), classes: [0])
    #expect(kept[0].rgb == (196, 214, 82))
}

private func squareRegion(_ x0: Int, _ y0: Int, side: Int, w: Int) -> Region {
    let pixels = (y0..<(y0 + side)).flatMap { y in (x0..<(x0 + side)).map { y * w + $0 } }
    return Region(minX: x0, minY: y0, maxX: x0 + side - 1, maxY: y0 + side - 1, pixels: pixels)
}

@Test func tileOutlineMustCoverMostOfTheTileNotAGlyph() {
    let w = 40
    let tile = squareRegion(10, 10, side: 20, w: w)
    func outline(faceSide: Int) -> [[Int]]? {
        let face = squareRegion(11, 11, side: faceSide, w: w)
        var faceOf = [Int32](repeating: -1, count: w * w)
        for i in face.pixels { faceOf[i] = 0 }
        return tilePolygon(tile, rect: CGRect(x: 10, y: 10, width: 20, height: 20), faces: [face], faceOf: faceOf, w: w, epsilon: 1)
    }
    #expect(outline(faceSide: 18) != nil)
    #expect(outline(faceSide: 4) == nil)
}

@Test func everyClassBelongsToTheLayerThatOwnsIt() {
    #expect(Layer.of(tile("Booth A", "A1")) == .booth)
    #expect(Layer.of(tile("SPONSOR BOOTH", nil)) == .booth)
    #expect(Layer.of(tile("wall", nil)) == .wall)
    #expect(Layer.of(tile("pillar", nil)) == .wall)
    #expect(Layer.of(tile("door", nil)) == .door)
    #expect(Layer.of(tile("object", nil)) == .seat)
}

@Test func layersOptionTakesNamesAndRejectsUnknownOnes() {
    #expect(parseOptions(["fp", "a.png", "b.png"])?.layers == Set(Layer.allCases))
    #expect(parseOptions(["fp", "a.png", "b.png", "--layers", "booth,wall"])?.layers == [.booth, .wall])
    #expect(parseOptions(["fp", "a.png", "b.png", "--layers", "tile"]) == nil)
    #expect(parseOptions(["fp", "a.png", "b.png"])?.upscaleSmall == false)
    #expect(parseOptions(["fp", "a.png", "b.png", "--upscale-small"])?.upscaleSmall == true)
}

@Test func upscaleOnlyEnlargesSmallTilesAndNeverBeyondTwice() {
    #expect(upscaleFactor(smallTileSide: 64) == 1)
    #expect(upscaleFactor(smallTileSide: 33) == 1)
    #expect(upscaleFactor(smallTileSide: 26) == 2)
    #expect(upscaleFactor(smallTileSide: 12) == 2)
    #expect(upscaleFactor(smallTileSide: nil) == 1)
}

private func flatPlan(noise: Int) -> Pixels {
    let (w, h) = (64, 64)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    var seed: UInt32 = 12345
    for y in 0..<h {
        for x in 0..<w {
            let line = x == 32
            seed = seed &* 1664525 &+ 1013904223
            for c in 0..<3 {
                let jitter = noise == 0 ? 0 : Int((seed >> UInt32(8 * c)) & 0xFF) % (2 * noise + 1) - noise
                rgba[(y * w + x) * 4 + c] = UInt8(max(0, min(255, (line ? 0 : 200) + jitter)))
            }
        }
    }
    return Pixels(width: w, height: h, rgba: rgba)
}

@Test func noiseScoreSeparatesCleanFromNoisyAndTheFilterKeepsThinLines() {
    #expect(noiseScore(flatPlan(noise: 0)) < 0.02)
    #expect(noiseScore(flatPlan(noise: 14)) > 0.07)
    let noisy = flatPlan(noise: 14)
    let smooth = sigmaFiltered(noisy)
    func range(_ px: Pixels) -> Int {
        let values = (5..<20).flatMap { y in (5..<25).map { x in Int(px.rgba[(y * 64 + x) * 4]) } }
        return values.max()! - values.min()!
    }
    #expect(range(smooth) < range(noisy))
    #expect(smooth.rgba[(30 * 64 + 32) * 4] < 40)  // the one-pixel black line is still black
}

@Test func resultsMapBackFromAnUpscaledImage() {
    var item = tile("Booth A", "A1")
    item.box = [100, 61, 40, 20]
    item.area = 800
    item.polygon = [[100, 60], [140, 60], [140, 80]]
    let back = scaledBack(item, by: 2)
    #expect(back.box == [50, 31, 20, 10])
    #expect(back.area == 200)
    #expect(back.polygon == [[50, 30], [70, 30], [70, 40]])
    #expect(scaledBack(item, by: 1).box == item.box)
}

private func inkWithRings(centers: [(Int, Int)], radius: Int, size: Int) -> [Bool] {
    var ink = [Bool](repeating: false, count: size * size)
    for (cx, cy) in centers {
        for y in (cy - radius - 1)...(cy + radius + 1) {
            for x in (cx - radius - 1)...(cx + radius + 1) {
                let d = (Double((x - cx) * (x - cx) + (y - cy) * (y - cy))).squareRoot()
                if d <= Double(radius) + 0.5, d > Double(radius) - 1 { ink[y * size + x] = true }
            }
        }
    }
    return ink
}

@Test func chairsAreRingsThatComeInSetsNotLoneCircles() {
    let size = 200
    let four = [(40, 40), (60, 40), (40, 60), (60, 60)]
    let found = chairs(ink: inkWithRings(centers: four + [(150, 150)], radius: 5, size: size), w: size, h: size, page: 2000)
    #expect(found.count == 4)
    #expect(found.allSatisfy { $0.midX < 100 })
}

@Test func squareHolesAreNotChairs() {
    let size = 100
    var ink = [Bool](repeating: false, count: size * size)
    for (cx, cy) in [(20, 20), (40, 20), (60, 20), (80, 20)] {
        for i in -6...6 {
            for (x, y) in [(cx + i, cy - 6), (cx + i, cy + 6), (cx - 6, cy + i), (cx + 6, cy + i)] { ink[y * size + x] = true }
        }
    }
    #expect(chairs(ink: ink, w: size, h: size, page: 2000).isEmpty)
}

@Test func rowsOfChairsMergeIntoOneGridButTablesInARowStayApart() {
    func blob(_ x: Double, _ y: Double, chairs: Int) -> Item {
        var item = outsideItem("object", CGRect(x: x, y: y, width: 100, height: 15), review: true, reason: nil)
        item.chairs = chairs
        return item
    }
    let rows = (0..<5).map { blob(0, Double($0) * 20, chairs: 10) }
    #expect(mergeChairGrids(rows, gap: 8).count == 1)
    let tables = (0..<4).map { blob(Double($0) * 102, 0, chairs: 4) }
    #expect(mergeChairGrids(tables, gap: 8).count == 4)
}
