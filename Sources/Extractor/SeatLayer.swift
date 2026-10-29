import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Seat layer: what is left once walls, columns and text are set aside, grouped by shape, plus each round chair
/// on its own. Tables with chairs, audience seating and stairs all arrive here as `object`. An object that holds
/// chairs is a seat; the judge may add seats the chair test missed but never removes one.
func seatLayer(_ s: InkScan, hollow: [Bool], px: Pixels, claimed: [Bool]) -> [Item] {
    let (w, h, n, mx, scale) = (s.w, s.h, s.n, s.mx, s.scale)
    let (inText, hs, vs, thick, compact) = (s.inText, s.hs, s.vs, s.thick, s.compact)
    var ink = s.ink
    let black = nearBlack(px)
    if inkLosesBlackLines(black: black, ink: s.rawInk) {
        for i in 0..<n where black[i] && !claimed[i] && !inText[i] { ink[i] = true }
    }
    var items: [Item] = []
    let chairRects = chairs(ink: ink, w: w, h: h, page: mx)

    var strokes = [Bool](repeating: false, count: n)
    for i in 0..<n { strokes[i] = hs[i] || vs[i] || thick[i] }
    let strokesNear = morph(strokes, w: w, h: h, rx: 3, ry: 3, erode: false)
    let pillarNear = morph(compact, w: w, h: h, rx: 4, ry: 4, erode: false)
    let hollowNear = morph(hollow, w: w, h: h, rx: 4, ry: 4, erode: false)
    var rest = [Bool](repeating: false, count: n)
    for i in 0..<n { rest[i] = ink[i] && !strokesNear[i] && !pillarNear[i] && !hollowNear[i] && !inText[i] }
    let joinRadius = objectJoinRadius(chairs: chairRects)
    let restNear = morph(rest, w: w, h: h, rx: joinRadius, ry: joinRadius, erode: false)

    struct Candidate { var rect: CGRect; var longSide: Double; var shortSide: Double; var fill: Double; var poly: [[Int]]? }
    var candidates: [Candidate] = []
    for reg in components(restNear, w: w, h: h, eight: true) {
        var x0 = w, y0 = h, x1 = 0, y1 = 0, count = 0
        var activePixels: [Int] = []
        for i in reg.pixels where rest[i] {
            let x = i % w, y = i / w
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y); count += 1
            activePixels.append(i)
        }
        guard count > 0 else { continue }
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        guard max(bw, bh) >= max(6, Int(0.003 * Double(mx))), Double(bw * bh) <= 0.25 * Double(n),
              Double(bw * bh) >= 160 * scale * scale else { continue }
        let hull = simplify(convexHull(activePixels, w: w, minY: y0, height: bh), epsilon: 2 * scale)
        let poly = hull.count >= 3 ? hull.map { [Int($0.0.rounded()), Int($0.1.rounded())] } : nil
        candidates.append(Candidate(
            rect: CGRect(x: x0, y: y0, width: bw, height: bh),
            longSide: Double(max(bw, bh)), shortSide: Double(min(bw, bh)),
            fill: Double(count) / Double(bw * bh), poly: poly))
    }
    var groups: [[Int]] = []
    for (i, c) in candidates.enumerated() {
        if let g = groups.firstIndex(where: { members in
            let ref = candidates[members[0]]
            return abs(ref.longSide - c.longSide) <= 0.1 * ref.longSide
                && abs(ref.shortSide - c.shortSide) <= 0.1 * ref.shortSide
                && abs(ref.fill - c.fill) <= 0.15
        }) {
            groups[g].append(i)
        } else {
            groups.append([i])
        }
    }
    for (g, members) in groups.enumerated() {
        for i in members {
            var it = outsideItem(
                "object", candidates[i].rect, review: true,
                reason: members.count > 1
                    ? "label this group once (group \(g + 1), \(members.count) shapes)"
                    : "unique shape, label it")
            it.polygon = candidates[i].poly
            let inside = chairRects.filter { candidates[i].rect.contains(CGPoint(x: $0.midX, y: $0.midY)) }.count
            it.seat = inside >= 2
            if it.seat == true {
                it.kind = "chair_group"
                it.chairs = inside
            }
            items.append(it)
        }
    }
    for rect in chairRects {
        var chair = outsideItem("object", rect, review: false, reason: "chair")
        chair.kind = "chair"
        chair.seat = true
        items.append(chair)
    }
    let chairSide = chairRects.map(\.width).sorted().dropFirst(chairRects.count / 2).first ?? 0
    return mergeChairGrids(items, gap: chairSide)
}

/// Dark pixels whatever their colour.
func nearBlack(_ px: Pixels) -> [Bool] {
    let n = px.width * px.height
    var gray = [UInt8](repeating: 0, count: n)
    var hist = [Int](repeating: 0, count: 256)
    for i in 0..<n {
        let v = UInt8((299 * Int(px.rgba[i * 4]) + 587 * Int(px.rgba[i * 4 + 1]) + 114 * Int(px.rgba[i * 4 + 2])) / 1000)
        gray[i] = v
        hist[Int(v)] += 1
    }
    var background = 255, seen = 0
    for v in 0..<256 {
        seen += hist[v]
        if seen * 2 >= n { background = v; break }
    }
    let cut = UInt8(Double(background) * 0.3)
    return gray.map { $0 < cut }
}

/// The shared ink mask needs low saturation, but JPEG and pixel noise tint the 1 px black outlines of chairs and
/// tables until they pass for a colour, and the lines vanish. On clean plans at least a third of the black pixels pass
/// (the rest border coloured fills); when under a fifth do, the saturation test is failing and black alone is used.
func inkLosesBlackLines(black: [Bool], ink: [Bool]) -> Bool {
    var total = 0, kept = 0
    for i in black.indices where black[i] {
        total += 1
        if ink[i] { kept += 1 }
    }
    return total > 0 && Double(kept) < 0.2 * Double(total)
}

/// How far ink is grown to join a table to its chairs. Two pixels suits chairs about twelve pixels across; on a
/// smaller print the gaps between neighbouring tables shrink with the chairs and two pixels would fuse them.
/// Never grows past two, so large plans keep their blobs. Without enough chairs to measure, it stays at two.
func objectJoinRadius(chairs: [CGRect]) -> Int {
    guard chairs.count >= 8 else { return 2 }
    let side = chairs.map(\.width).sorted()[chairs.count / 2]
    return min(2, max(1, Int((side / 6).rounded())))
}

/// A grid of chairs reaches the layer as one blob per row. Rows of six or more chairs that touch are one audience block;
/// a table has four or fewer chairs, so tables set in a row never merge.
func mergeChairGrids(_ items: [Item], gap: Double) -> [Item] {
    let rows = items.indices.filter { (items[$0].chairs ?? 0) >= 6 }
    var parent = Dictionary(uniqueKeysWithValues: rows.map { ($0, $0) })
    func find(_ x: Int) -> Int {
        var r = x
        while parent[r]! != r { r = parent[r]! }
        return r
    }
    for (k, a) in rows.enumerated() {
        for b in rows[(k + 1)...] where items[a].rect.insetBy(dx: -gap, dy: -gap).intersects(items[b].rect) {
            parent[find(b)] = find(a)
        }
    }
    var members: [Int: [Int]] = [:]
    for r in rows { members[find(r), default: []].append(r) }
    var merged = Set<Int>()
    var grids: [Item] = []
    for group in members.values where group.count > 1 {
        let rect = group.dropFirst().reduce(items[group[0]].rect) { $0.union(items[$1].rect) }
        var grid = outsideItem("object", rect, review: true, reason: "grid of chairs")
        grid.kind = "chair_group"
        grid.chairs = group.reduce(0) { $0 + (items[$1].chairs ?? 0) }
        grid.seat = true
        grids.append(grid)
        merged.formUnion(group)
    }
    return items.indices.filter { !merged.contains($0) }.map { items[$0] } + grids
}

/// Chairs are small closed holes in the ink: a ring with a clear inside, touching the table or not.
/// A lone circle can be a letter, a dot or a column, so a hole counts only with two more of its own size close by.
func chairs(ink: [Bool], w: Int, h: Int, page: Int) -> [CGRect] {
    let n = w * h
    let smallest = max(3, Int(0.001 * Double(page)))
    let largest = max(smallest, Int(0.015 * Double(page)))

    struct Hole { var rect: CGRect; var diameter: Double }
    var holes: [Hole] = []
    var seen = [Bool](repeating: false, count: n)
    var stack: [Int] = []
    for start in 0..<n where !ink[start] && !seen[start] {
        seen[start] = true
        stack.append(start)
        var x0 = w, x1 = 0, y0 = h, y1 = 0, count = 0
        var open = false
        var members: [Int] = []
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            count += 1
            if count <= largest * largest { members.append(i) }
            if x == 0 || y == 0 || x == w - 1 || y == h - 1 { open = true }
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            if x > 0, !ink[i - 1], !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
            if x < w - 1, !ink[i + 1], !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
            if y > 0, !ink[i - w], !seen[i - w] { seen[i - w] = true; stack.append(i - w) }
            if y < h - 1, !ink[i + w], !seen[i + w] { seen[i + w] = true; stack.append(i + w) }
        }
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        let diameter = max(bw, bh)
        guard !open, (smallest...largest).contains(diameter), diameter * 4 <= min(bw, bh) * 5 else { continue }
        // A disc fills about 0.78 of its box and leaves the box corners empty, a square or rounded square does not.
        let hole = Set(members)
        let corners = [y0 * w + x0, y0 * w + x1, y1 * w + x0, y1 * w + x1]
        let fill = Double(count) / Double(bw * bh)
        guard (0.6...0.97).contains(fill), !corners.contains(where: hole.contains) else { continue }
        // The ring is as thick as the ink run next to the hole, taken at the thinnest side because a table may share it.
        func run(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int) -> Int {
            var (cx, cy, length) = (x + dx, y + dy, 0)
            while cx >= 0, cy >= 0, cx < w, cy < h, ink[cy * w + cx] { length += 1; cx += dx; cy += dy }
            return length
        }
        let (mxc, myc) = ((x0 + x1) / 2, (y0 + y1) / 2)
        let thickness = max(1, min(run(x0, myc, -1, 0), run(x1, myc, 1, 0), run(mxc, y0, 0, -1), run(mxc, y1, 0, 1)))
        holes.append(Hole(
            rect: CGRect(x: x0 - thickness, y: y0 - thickness, width: bw + 2 * thickness, height: bh + 2 * thickness),
            diameter: Double(diameter)))
    }
    return holes.filter { a in
        holes.filter { b in
            abs(a.diameter - b.diameter) <= max(1.5, 0.2 * a.diameter)
                && hypot(a.rect.midX - b.rect.midX, a.rect.midY - b.rect.midY) <= 6 * a.diameter
        }.count >= 3
    }.map(\.rect)
}
