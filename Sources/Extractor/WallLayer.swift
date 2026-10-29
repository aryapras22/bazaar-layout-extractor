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
    return WallResult(items: items, bands: wallBands, fallback: fallback)
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
