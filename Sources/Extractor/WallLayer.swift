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
    for s in reviewSegs {
        items.append(outsideItem("wall", s.rect, review: true, reason: "single line, not confirmed as a wall"))
    }

    let minTotal = Int(0.4 * Double(mx))
    let tolerance = max(3, Int((0.006 * Double(mx)).rounded()))
    var wallBands = bands(confidentSegs, tolerance: tolerance, minTotal: minTotal)
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

    let axis = zip(longRuns(ink, w: w, h: h, minLen: s.longest, horizontal: true),
                   longRuns(ink, w: w, h: h, minLen: s.longest, horizontal: false)).map { $0 || $1 }
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
func columnLayer(_ s: InkScan) -> (items: [Item], hollow: [Bool]) {
    let (w, h, n, mx, longest) = (s.w, s.h, s.n, s.mx, s.longest)
    let (rawInk, inText, textBoxes, pillars) = (s.rawInk, s.inText, s.textBoxes, s.solidRegions)
    var items: [Item] = []

    for reg in pillars {
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
    for reg in components(cores, w: w, h: h, eight: true) {
        let side = Double(max(reg.width, reg.height))
        guard side >= 0.005 * Double(mx), side <= 0.02 * Double(mx),
              Double(max(reg.width, reg.height)) <= 1.5 * Double(min(reg.width, reg.height)),
              reg.fill >= 0.8,
              reg.pixels.filter({ loopInk[$0] }).count * 10 < reg.area * 8 else { continue }
        let center = CGPoint(x: Double(reg.minX + reg.maxX) / 2, y: Double(reg.minY + reg.maxY) / 2)
        if textBoxes.contains(where: { $0.contains(center) }) { continue }
        for i in reg.pixels { hollow[i] = true }
        let rect = CGRect(x: reg.minX, y: reg.minY, width: reg.width, height: reg.height)
        items.append(outsideItem("pillar", rect, review: true, reason: "hollow square, confirm it is a pillar"))
    }
    return (items, hollow)
}
