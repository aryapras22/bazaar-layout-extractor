import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct WallResult {
    let items: [Item]
    let bands: [Band]
    let fallback: Bool
}

/// Wall layer: horizontal and vertical wall strokes, confirmed by a second parallel line or by thickness.
func wallLayer(_ s: InkScan) -> WallResult {
    let (w, h, n, mx, longest, ink) = (s.w, s.h, s.n, s.mx, s.longest, s.ink)
    let (hs, vs, thick) = (s.hs, s.vs, s.thick)
    var items: [Item] = []

    let dmin = max(2, Int((0.0012 * Double(mx)).rounded()))
    let dmax = max(4, Int((0.004 * Double(mx)).rounded()))
    var confH = pairs(hs, ink: ink, w: w, h: h, dmin: dmin, dmax: dmax, horizontal: true)
    var confV = pairs(vs, ink: ink, w: w, h: h, dmin: dmin, dmax: dmax, horizontal: false)
    for i in 0..<n where thick[i] {
        if hs[i] { confH[i] = true }
        if vs[i] { confV[i] = true }
    }
    let nearH = morph(confH, w: w, h: h, rx: 0, ry: dmax, erode: false)
    let nearV = morph(confV, w: w, h: h, rx: dmax, ry: 0, erode: false)
    var reviewH = hs, reviewV = vs
    for i in 0..<n {
        if nearH[i] { reviewH[i] = false }
        if nearV[i] { reviewV[i] = false }
    }
    let confidentSegs =
        segments(confH, w: w, h: h, horizontal: true, pad: dmax, confident: true, minLength: longest)
        + segments(confV, w: w, h: h, horizontal: false, pad: dmax, confident: true, minLength: longest)
    let reviewSegs =
        segments(reviewH, w: w, h: h, horizontal: true, pad: 1, confident: false, minLength: longest)
        + segments(reviewV, w: w, h: h, horizontal: false, pad: 1, confident: false, minLength: longest)
    for s in confidentSegs {
        items.append(outsideItem("wall", s.rect, review: false, reason: nil))
    }
    let minTotal = Int(0.4 * Double(mx))
    let tolerance = max(3, Int((0.006 * Double(mx)).rounded()))
    var wallBands = bands(confidentSegs, tolerance: tolerance, minTotal: minTotal)
    // Plan 1: when the hall edges are double-line walls, long 1-2 px single lines (length >= 3 * longest, stroke <= 3) are inner hall borders or symbol outlines, not walls.
    for s in reviewSegs where wallBands.isEmpty || s.length < 3 * longest || min(Int(s.rect.width), Int(s.rect.height)) >= 4 {
        items.append(outsideItem("wall", s.rect, review: true, reason: "single line, not confirmed as a wall"))
    }
    var fallback = false
    if wallBands.isEmpty {
        fallback = true
        let lineBands = bands(reviewSegs, tolerance: tolerance, minTotal: minTotal)
        for horizontal in [true, false] {
            let group = lineBands.filter { $0.horizontal == horizontal }.sorted { $0.center < $1.center }
            if let first = group.first { wallBands.append(first) }
            if group.count > 1, let last = group.last { wallBands.append(last) }
        }
    }
    return WallResult(items: items + slantedWalls(s), bands: wallBands, fallback: fallback)
}

/// Slanted walls: strokes at an angle to both axes, kept only when they join an axis-aligned wall and are not
/// part of an X symbol. Booths are not masked here, because the booth layer's claimed areas can be wrong
/// (plan 5 holds false white tiles over a real corner wall); booth outlines are axis-aligned and drop out below.
func slantedWalls(_ s: InkScan) -> [Item] {
    let (w, h, mx, scale) = (s.w, s.h, s.mx, s.scale)
    var ink = s.rawInk
    for i in 0..<s.n where s.inText[i] { ink[i] = false }

    let axis = zip(tiltedRuns(ink, w: w, h: h, minLen: s.longest, horizontal: true, tilt: s.tilt.h),
                   tiltedRuns(ink, w: w, h: h, minLen: s.longest, horizontal: false, tilt: s.tilt.v)).map { $0 || $1 }
    let axisNear = morph(axis, w: w, h: h, rx: 2, ry: 2, erode: false)
    let axisReach = morph(axis, w: w, h: h, rx: 5, ry: 5, erode: false)

    // Solid blocks and the text cut out of them (sponsor boxes) are not strokes. Closing joins the glyph gaps.
    let k = max(7, Int((0.004 * Double(mx)).rounded()) | 1)
    let solid = morph(morph(ink, w: w, h: h, rx: k / 2, ry: k / 2, erode: true), w: w, h: h, rx: k / 2, ry: k / 2, erode: false)
    let closeRadius = max(4, Int((8 * scale).rounded()))
    let blocks = morph(morph(solid, w: w, h: h, rx: closeRadius, ry: closeRadius, erode: false),
                       w: w, h: h, rx: closeRadius, ry: closeRadius, erode: true)
    let blocksNear = morph(blocks, w: w, h: h, rx: 3, ry: 3, erode: false)

    var residual = ink
    for i in 0..<s.n where axisNear[i] || blocksNear[i] { residual[i] = false }

    let minLength = 0.02 * Double(mx)
    var strokes = slantedStrokes(residual, w: w, h: h, minLength: minLength, gap: max(4, 0.003 * Double(mx)))
    strokes = strokes.map { extendedAlongInk($0, ink: ink, axis: axisNear, w: w, h: h, maxGap: 3, overlap: 4) }

    func joinsAxisWall(_ p: (Double, Double)) -> Bool {
        let (x, y) = (Int(p.0.rounded()), Int(p.1.rounded()))
        return x >= 0 && y >= 0 && x < w && y < h && axisReach[y * w + x]
    }
    // A box with a cross drawn in it: ink on both sides of the stroke, close together along it, is a second line
    // crossing. A double-line wall has its partner on one side only.
    func crossedByOtherLine(_ st: Slant) -> Bool {
        let (ux, uy) = st.unit
        let reach = Int((12 * scale).rounded())
        var sideHits: [[Int]] = [[], []]
        for t in Int(0.25 * st.length)...Int(0.75 * st.length) {
            for (k, sign) in [1.0, -1.0].enumerated() {
                let hit = (4...6).contains { o in
                    let x = Int((st.x0 + ux * Double(t) - uy * Double(o) * sign).rounded())
                    let y = Int((st.y0 + uy * Double(t) + ux * Double(o) * sign).rounded())
                    return x >= 0 && y >= 0 && x < w && y < h && residual[y * w + x]
                }
                if hit { sideHits[k].append(t) }
            }
        }
        return sideHits[0].contains { a in sideHits[1].contains { abs($0 - a) <= reach } }
    }
    let kept = strokes.enumerated().filter { i, st in
        (joinsAxisWall((st.x0, st.y0)) || joinsAxisWall((st.x1, st.y1)))
            && !strokes.enumerated().contains { j, other in j != i && slantsCross(st, other) }
            && !crossedByOtherLine(st)
    }.map(\.element)

    return mergedSlants(kept, separation: max(8, 0.004 * Double(mx)), gap: max(6, 0.004 * Double(mx))).map { st in
        let half = st.width / 2
        let rect = CGRect(x: min(st.x0, st.x1) - half, y: min(st.y0, st.y1) - half,
                          width: abs(st.x1 - st.x0) + st.width, height: abs(st.y1 - st.y0) + st.width)
        var item = outsideItem("wall", rect, review: false, reason: nil)
        item.segment = [st.x0, st.y0, st.x1, st.y1].map { Int($0.rounded()) }
        item.width = (st.width * 10).rounded() / 10
        item.area = Int(st.length * st.width)
        return item
    }
}

/// Column part of the wall layer: solid squares, and hollow squares crossed by a wall line.
func columnLayer(_ s: InkScan, bands: [Band] = []) -> (items: [Item], hollow: [Bool]) {
    let (w, h, n, mx, longest) = (s.w, s.h, s.n, s.mx, s.longest)
    let (rawInk, inText, textBoxes, pillars) = (s.rawInk, s.inText, s.textBoxes, s.solidRegions)
    var items: [Item] = []

    for reg in pillars {
        // Plan 1: the upside-down stage block (403 x 205 grey fill) has no readable label, so only its size rules it out.
        if reg.width > Int(0.04 * Double(mx)) || reg.height > Int(0.04 * Double(mx)) { continue }
        let center = CGPoint(x: Double(reg.minX + reg.maxX) / 2, y: Double(reg.minY + reg.maxY) / 2)
        if textBoxes.contains(where: { $0.contains(center) }) { continue }
        let rect = CGRect(x: reg.minX, y: reg.minY, width: reg.width, height: reg.height)
        items.append(outsideItem("pillar", rect, review: true, reason: "solid shape, confirm it is a pillar"))
    }

    // Hollow squares are closed small loops. Filling them and opening past the wall-line
    // thickness leaves a solid core even where a wall line runs through the square.
    var loopInk = rawInk
    for i in 0..<n where inText[i] { loopInk[i] = false }
    let filled = fillHoles(loopInk, w: w, h: h, maxHole: Int(pow(0.02 * Double(mx), 2)), seamLength: longest)
    let coreRadius = max(3, Int((0.002 * Double(mx)).rounded()))
    let cores = morph(morph(filled, w: w, h: h, rx: coreRadius, ry: coreRadius, erode: true),
                      w: w, h: h, rx: coreRadius, ry: coreRadius, erode: false)
    var hollow = [Bool](repeating: false, count: n)
    var squareSides: [Int] = []
    var merged: [Region] = []
    for reg in components(cores, w: w, h: h, eight: true) {
        let side = Double(max(reg.width, reg.height))
        if side > 0.02 * Double(mx) { merged.append(reg) }
        guard side >= 0.005 * Double(mx), side <= 0.02 * Double(mx),
              Double(max(reg.width, reg.height)) <= 1.5 * Double(min(reg.width, reg.height)),
              reg.fill >= 0.8,
              reg.pixels.filter({ loopInk[$0] }).count * 10 < reg.area * 8 else { continue }
        let center = CGPoint(x: Double(reg.minX + reg.maxX) / 2, y: Double(reg.minY + reg.maxY) / 2)
        if textBoxes.contains(where: { $0.contains(center) }) { continue }
        for i in reg.pixels { hollow[i] = true }
        squareSides.append(max(reg.width, reg.height))
        let rect = CGRect(x: reg.minX, y: reg.minY, width: reg.width, height: reg.height)
        items.append(outsideItem("pillar", rect, review: true, reason: "hollow square, confirm it is a pillar"))
    }

    // A square drawn against a symbol outline (plan 1: the north-wall squares touch an entrance box) fuses with it
    // into one core that is too big for the pass above. Look for the same size of square inside such a core: a
    // window whose four edges are all ink.
    if !squareSides.isEmpty {
        let side = squareSides.sorted()[squareSides.count / 2]
        let edge = max(2, Int((0.001 * Double(mx)).rounded()))
        func inked(_ x: Int, _ y: Int, alongX: Bool) -> Bool {
            (0..<edge).contains { k in
                let (px, py) = alongX ? (x, y + k) : (x + k, y)
                return px < w && py < h && loopInk[py * w + px]
            }
        }
        func edgeIsInk(_ x: Int, _ y: Int, alongX: Bool) -> Bool {
            (0..<side).allSatisfy { inked(alongX ? x + $0 : x, alongX ? y : y + $0, alongX: alongX) }
        }
        // Plan 1: a wall line or two cross a pillar (about a third of the inside), while grey fill (the stage) or
        // stairs (plan 6) fill most of it or have ink running perpendicular to the wall.
        func isHollow(_ x: Int, _ y: Int, horizontalWall: Bool) -> Bool {
            var inkCount = 0
            for yy in (y + edge)..<(y + side - edge) {
                for xx in (x + edge)..<(x + side - edge) where yy < h && xx < w && loopInk[yy * w + xx] { inkCount += 1 }
            }
            let inside = (side - 2 * edge) * (side - 2 * edge)
            guard inkCount * 2 < inside else { return false }
            let clearSpan = (y + edge)..<(y + side - edge)
            if horizontalWall {
                return !( (x + edge)..<(x + side - edge) ).contains { xx in
                    clearSpan.allSatisfy { yy in yy < h && xx < w && loopInk[yy * w + xx] }
                }
            } else {
                let clearX = (x + edge)..<(x + side - edge)
                return !clearSpan.contains { yy in
                    clearX.allSatisfy { xx in yy < h && xx < w && loopInk[yy * w + xx] }
                }
            }
        }
        for reg in merged {
            var found: [CGRect] = []
            for y in reg.minY...max(reg.minY, reg.maxY - side + 1) {
                for x in reg.minX...max(reg.minX, reg.maxX - side + 1) {
                    let rect = CGRect(x: x, y: y, width: side, height: side)
                    guard let band = bands.first(where: { b in
                        b.horizontal
                            ? (Int(rect.minY)...Int(rect.maxY)).overlaps(b.c0...b.c1) && (Int(rect.minX)...Int(rect.maxX)).overlaps(b.lo...b.hi)
                            : (Int(rect.minX)...Int(rect.maxX)).overlaps(b.c0...b.c1) && (Int(rect.minY)...Int(rect.maxY)).overlaps(b.lo...b.hi)
                    }) else { continue }
                    guard edgeIsInk(x, y, alongX: true), edgeIsInk(x, y, alongX: false),
                          edgeIsInk(x + side - edge, y, alongX: false),
                          edgeIsInk(x, y + side - edge, alongX: true), isHollow(x, y, horizontalWall: band.horizontal) else { continue }
                    if found.contains(where: { $0.insetBy(dx: -Double(side) / 2, dy: -Double(side) / 2).intersects(rect) }) { continue }
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    if textBoxes.contains(where: { $0.contains(center) }) { continue }
                    found.append(rect)
                    items.append(outsideItem("pillar", rect, review: true, reason: "hollow square against a symbol outline, confirm it is a pillar"))
                }
            }
        }
    }

    // Round columns are rings, often with a bar across, so the bar splits the inside into two holes that the
    // square pass may leave open. A disc fills pi/4 of its box, which the square pass rejects by design; here
    // that fill, a square box, an empty inside and clear space around it are the test. A round table has chairs
    // within half a diameter; a column stands alone or against a wall.
    let roomy = fillHoles(loopInk, w: w, h: h, maxHole: Int(pow(0.05 * Double(mx), 2)), seamLength: longest)
    let discs = morph(morph(roomy, w: w, h: h, rx: coreRadius, ry: coreRadius, erode: true),
                      w: w, h: h, rx: coreRadius, ry: coreRadius, erode: false)
    for reg in components(discs, w: w, h: h, eight: true) {
        let side = Double(max(reg.width, reg.height))
        guard side >= 0.008 * Double(mx), side <= 0.04 * Double(mx),
              side <= 1.12 * Double(min(reg.width, reg.height)),
              (0.72...0.84).contains(reg.fill),
              reg.pixels.filter({ loopInk[$0] }).count * 2 < reg.area else { continue }
        let center = CGPoint(x: Double(reg.minX + reg.maxX) / 2, y: Double(reg.minY + reg.maxY) / 2)
        if textBoxes.contains(where: { $0.contains(center) }) { continue }
        if items.contains(where: { $0.cls == "pillar" && $0.rect.contains(center) }) { continue }
        let radius = side / 2
        var ring = 0, crowded = 0
        for y in max(0, Int(center.y - 1.5 * radius))...min(h - 1, Int(center.y + 1.5 * radius)) {
            for x in max(0, Int(center.x - 1.5 * radius))...min(w - 1, Int(center.x + 1.5 * radius)) {
                let d = hypot(Double(x) - Double(center.x), Double(y) - Double(center.y))
                if d > radius + 2, d <= 1.5 * radius { ring += 1; if loopInk[y * w + x] { crowded += 1 } }
            }
        }
        if Double(crowded) > 0.15 * Double(ring) { continue }
        for i in reg.pixels { hollow[i] = true }
        let rect = CGRect(x: reg.minX, y: reg.minY, width: reg.width, height: reg.height)
        items.append(outsideItem("pillar", rect, review: true, reason: "round column, confirm it is a pillar"))
    }
    return (items, hollow)
}
