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
    return swingSymbols(dominant(arcs)).map { group in
        let rect = group.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        let radius = group.map(\.r).max() ?? 0
        return outsideItem("door", rect.insetBy(dx: -1, dy: -1), review: true,
                           reason: "swing symbol, \(group.count) arc" + (group.count == 1 ? "" : "s") + ", r=\(Int(radius))")
    }
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
