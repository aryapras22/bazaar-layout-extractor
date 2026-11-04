import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Door layer: swing symbols, meaning door-leaf arcs standing on a wall.
func doorLayer(_ s: InkScan, walls: WallResult) -> [Item] {
    let (w, h, n, mx, rawInk) = (s.w, s.h, s.n, s.mx, s.rawInk)

    var thin = rawInk
    for i in 0..<n where s.inText[i] || s.thick[i] || s.compact[i] { thin[i] = false }
    let finder = ArcFinder(w: w, h: h, thin: thin, minRadius: max(6, Int(0.005 * Double(mx))), maxRadius: Int(0.03 * Double(mx)))
    func touchesWall(_ a: Arc) -> Bool {
        let box = a.rect.insetBy(dx: -0.6 * a.r, dy: -0.6 * a.r)
        for y in max(0, Int(box.minY))...min(h - 1, Int(box.maxY)) {
            for x in max(0, Int(box.minX))...min(w - 1, Int(box.maxX)) where s.hs[y * w + x] || s.vs[y * w + x] { return true }
        }
        return false
    }
    let arcs = finder.arcs().filter { $0.bad <= 0.3 && $0.interior <= 0.35 && $0.r >= 4.5 * $0.stroke && touchesWall($0) }
    let swings = swingSymbols(dominant(arcs)).map { group in
        let rect = group.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        let radius = group.map(\.r).max() ?? 0
        return outsideItem("door", rect.insetBy(dx: -1, dy: -1), review: true,
                           reason: "swing symbol, \(group.count) arc" + (group.count == 1 ? "" : "s") + ", r=\(Int(radius))")
    }
    return swings + swings.compactMap { opening(at: $0.rect, walls: walls) }
}

/// The opening a swing symbol stands in: a wall band that runs through the symbol and past it on both sides, with
/// no confirmed wall along at least half of the symbol's width. The box is that unwalled run across the band.
func opening(at swing: CGRect, walls: WallResult) -> Item? {
    let solid = walls.items.filter { $0.cls == "wall" && !$0.needsReview && $0.segment == nil }
    for band in walls.bands {
        let (across, along) = band.horizontal
            ? (Int(swing.minY)...Int(swing.maxY), Int(swing.minX)..<Int(swing.maxX))
            : (Int(swing.minX)...Int(swing.maxX), Int(swing.minY)..<Int(swing.maxY))
        guard across.overlaps(band.c0...band.c1), band.lo < along.lowerBound, band.hi >= along.upperBound else { continue }
        var walled = [Bool](repeating: false, count: along.count)
        for wall in solid {
            let r = wall.rect
            let (wallAcross, wallAlong) = band.horizontal ? (Int(r.minY)...Int(r.maxY), Int(r.minX)..<Int(r.maxX))
                                                          : (Int(r.minX)...Int(r.maxX), Int(r.minY)..<Int(r.maxY))
            guard wallAcross.overlaps(band.c0...band.c1) else { continue }
            for k in wallAlong.clamped(to: along) { walled[k - along.lowerBound] = true }
        }
        var best = 0..<0, start: Int?
        for k in 0...walled.count {
            if k < walled.count, !walled[k] { if start == nil { start = k }; continue }
            if let s = start, k - s > best.count { best = s..<k }
            start = nil
        }
        guard best.count * 2 >= along.count else { continue }
        let (a, b) = (along.lowerBound + best.lowerBound, along.lowerBound + best.upperBound)
        let rect = band.horizontal
            ? CGRect(x: a, y: band.c0, width: b - a, height: band.c1 - band.c0 + 1)
            : CGRect(x: band.c0, y: a, width: band.c1 - band.c0 + 1, height: b - a)
        return outsideItem("opening", rect, review: true, reason: "gap in a wall band under a swing symbol")
    }
    return nil
}

/// Corners of jamb posts and gate boxes also fit small arcs. Next to a swing at least a third larger they are
/// part of its detail, not doors of their own.
func dominant(_ arcs: [Arc]) -> [Arc] {
    var kept: [Arc] = []
    for arc in arcs.sorted(by: { $0.r > $1.r }) {
        let reach = 0.3 * arc.r
        let dwarfed = kept.contains { big in
            arc.r < 0.75 * big.r && big.rect.insetBy(dx: -reach, dy: -reach).intersects(arc.rect)
        }
        if !dwarfed { kept.append(arc) }
    }
    return kept
}

/// Arcs that touch or overlap, such as the two halves of a double door, belong to one symbol.
func swingSymbols(_ arcs: [Arc]) -> [[Arc]] {
    var parent = Array(arcs.indices)
    func find(_ i: Int) -> Int {
        var i = i
        while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
        return i
    }
    for i in arcs.indices {
        for j in arcs.indices where j > i {
            let reach = 0.3 * max(arcs[i].r, arcs[j].r)
            if arcs[i].rect.insetBy(dx: -reach, dy: -reach).intersects(arcs[j].rect) { parent[find(i)] = find(j) }
        }
    }
    var groups: [Int: [Arc]] = [:]
    for i in arcs.indices { groups[find(i), default: []].append(arcs[i]) }
    return groups.keys.sorted().map { groups[$0]! }
}
