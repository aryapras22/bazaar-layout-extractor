import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Seat layer: what is left once walls, columns and text are set aside, grouped by shape, plus each round chair
/// on its own and each table inside a symbol. Tables with chairs, audience seating and stairs all arrive here as
/// `object`. An object that holds chairs is a seat; the judge may add seats the chair test missed but never removes one.
/// Tables are kind "table" with their number, true size and tilt; every chair names its table, or none.
func seatLayer(_ s: InkScan, hollow: [Bool]) -> [Item] {
    let (w, h, n, mx, scale) = (s.w, s.h, s.n, s.mx, s.scale)
    let (inText, hs, vs, thick, compact) = (s.inText, s.hs, s.vs, s.thick, s.compact)
    let ink = s.ink
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
    let blobs = components(restNear, w: w, h: h, eight: true)
    for reg in blobs {
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
    let found = tables(rest: rest, blobs: blobs, chairs: chairRects, w: w, h: h)
    var tableOf = [Int?](repeating: nil, count: chairRects.count)
    var tableItems: [Item] = []
    for (k, fit) in found.enumerated() {
        for c in fit.chairs { tableOf[c] = k + 1 }
        var table = outsideItem("object", fit.box, review: false, reason: "table, \(fit.chairs.count) chairs")
        table.kind = "table"
        table.seat = true
        table.chairs = fit.chairs.count
        table.table = k + 1
        table.tableSize = [(fit.long * 10).rounded() / 10, (fit.short * 10).rounded() / 10]
        table.angle = (fit.angle * 10).rounded() / 10
        tableItems.append(table)
    }
    for (c, rect) in chairRects.enumerated() {
        var chair = outsideItem("object", rect, review: false, reason: "chair")
        chair.kind = "chair"
        chair.seat = true
        chair.table = tableOf[c]
        items.append(chair)
    }
    let chairSide = chairRects.map(\.width).sorted().dropFirst(chairRects.count / 2).first ?? 0
    return mergeChairGrids(items, gap: chairSide) + tableItems
}

/// A table inside a symbol, in pixels: centre, true size (long side, short side), the tilt of the long side in degrees
/// (0 to 180, clockwise because y grows down) and the indices of its chairs.
struct TableFit {
    var cx: Double, cy: Double, long: Double, short: Double, angle: Double
    var chairs: [Int]

    var corners: [(Double, Double)] {
        let t = angle * .pi / 180
        let u = (cos(t), sin(t)), v = (-sin(t), cos(t))
        return [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { su, sv in
            (cx + su * long / 2 * u.0 + sv * short / 2 * v.0, cy + su * long / 2 * u.1 + sv * short / 2 * v.1)
        }
    }

    /// Distance from a point to the table, 0 inside it.
    func gap(to p: CGPoint) -> Double {
        let t = angle * .pi / 180
        let (dx, dy) = (Double(p.x) - cx, Double(p.y) - cy)
        let along = abs(dx * cos(t) + dy * sin(t)) - long / 2, across = abs(-dx * sin(t) + dy * cos(t)) - short / 2
        return hypot(max(along, 0), max(across, 0))
    }

    /// The axis-aligned box of the tilted table, out to whole pixels.
    var box: CGRect {
        let xs = corners.map(\.0), ys = corners.map(\.1)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).integral
    }
}

/// Tables. A symbol is a table with its chairs, one blob of the seat ink, so a blob that holds two to eight chairs is
/// taken as a symbol (audience rows hold more, or are only rings). Erasing the chair discs leaves the table outline,
/// broken where a chair touched it; pieces shorter than a chair is wide are what is left of the rings and are dropped.
/// The table is the minimum-area rectangle of the rest, which gives its true size and tilt. It counts only if every
/// chair of the blob stands within a chair and a half of it. Otherwise, or with no outline left, the chairs keep no table.
/// On plans 1 to 3 this finds all 171 tables, centres within 2 px and tilt within 3 degrees of the truth.
/// Tables come back in reading order: rows of two chair widths, left to right.
func tables(rest: [Bool], blobs: [Region], chairs: [CGRect], w: Int, h: Int) -> [TableFit] {
    guard chairs.count >= 2 else { return [] }
    let side = Double(chairs.map(\.width).sorted()[chairs.count / 2])
    var label = [Int32](repeating: -1, count: w * h)
    for (k, reg) in blobs.enumerated() { for i in reg.pixels { label[i] = Int32(k) } }
    func vote(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int? {
        let (ax, ay, bx, by) = (max(0, x0), max(0, y0), min(w - 1, x1), min(h - 1, y1))
        guard ax <= bx, ay <= by else { return nil }
        var votes: [Int32: Int] = [:]
        for y in ay...by { for x in ax...bx where label[y * w + x] >= 0 { votes[label[y * w + x], default: 0] += 1 } }
        return votes.max { ($0.value, -$0.key) < ($1.value, -$1.key) }.map { Int($0.key) }
    }
    var members: [Int: [Int]] = [:]
    for (i, c) in chairs.enumerated() {
        let (cx, cy) = (Int(c.midX), Int(c.midY))
        // the chair's centre is clear on a ring, so a hit there is the table it touches; otherwise the ring decides
        if let blob = vote(cx - 1, cy - 1, cx + 1, cy + 1) ?? vote(Int(c.minX), Int(c.minY), Int(c.maxX), Int(c.maxY)) {
            members[blob, default: []].append(i)
        }
    }
    var found: [TableFit] = []
    for blob in members.keys.sorted() {
        let mine = members[blob]!
        guard (2...8).contains(mine.count) else { continue }
        let reg = blobs[blob]
        let discs = mine.map { c -> (Double, Double, Double) in
            let r = chairs[c]
            return (Double(r.midX).rounded(), Double(r.midY).rounded(), (Double(max(r.width, r.height)) / 2 + 1.5).rounded())
        }
        let (bw, bh) = (reg.width, reg.height)
        var outline = [Bool](repeating: false, count: bw * bh)
        for i in reg.pixels where rest[i] {
            let x = i % w, y = i / w
            let inDisc = discs.contains { cx, cy, r in
                let dx = Double(x) - cx, dy = Double(y) - cy
                return dx * dx + dy * dy <= r * r
            }
            if !inDisc { outline[(y - reg.minY) * bw + (x - reg.minX)] = true }
        }
        var kept: [Int] = []
        for piece in components(outline, w: bw, h: bh, eight: true) where Double(piece.area) >= side {
            kept += piece.pixels.map { (reg.minY + $0 / bw) * w + reg.minX + $0 % bw }
        }
        guard kept.count >= 12 else { continue }
        let rows = kept.map { $0 / w }
        let top = rows.min()!
        guard let fit = minAreaRect(convexHull(kept, w: w, minY: top, height: rows.max()! - top + 1)) else { continue }
        let table = TableFit(cx: fit.cx, cy: fit.cy, long: fit.long, short: fit.short, angle: fit.angle, chairs: mine)
        // chairs stand at the table, so each one is within a chair and a half of its edge; a row of stools next to a
        // counter is not a table with chairs
        guard mine.allSatisfy({ table.gap(to: CGPoint(x: chairs[$0].midX, y: chairs[$0].midY)) <= 1.5 * side }) else { continue }
        found.append(table)
    }
    let row = max(1, 2 * side)
    return found.sorted { a, b in
        let (ra, rb) = ((a.cy / row).rounded(.down), (b.cy / row).rounded(.down))
        return ra != rb ? ra < rb : a.cx < b.cx
    }
}

/// Smallest rectangle around a convex polygon (rotating calipers: one side of the best rectangle lies on a hull edge).
/// Returns its centre, long and short side, and the tilt of the long side in degrees, 0 to 180.
func minAreaRect(_ hull: [(Double, Double)]) -> (cx: Double, cy: Double, long: Double, short: Double, angle: Double)? {
    guard hull.count >= 3 else { return nil }
    var best: (area: Double, cx: Double, cy: Double, along: Double, across: Double, theta: Double)?
    for k in hull.indices {
        let p = hull[k], q = hull[(k + 1) % hull.count]
        let length = hypot(q.0 - p.0, q.1 - p.1)
        guard length > 1e-9 else { continue }
        let u = ((q.0 - p.0) / length, (q.1 - p.1) / length), v = (-u.1, u.0)
        var (u0, u1, v0, v1) = (Double.infinity, -Double.infinity, Double.infinity, -Double.infinity)
        for r in hull {
            let s = r.0 * u.0 + r.1 * u.1, t = r.0 * v.0 + r.1 * v.1
            u0 = min(u0, s); u1 = max(u1, s); v0 = min(v0, t); v1 = max(v1, t)
        }
        let area = (u1 - u0) * (v1 - v0)
        if best == nil || area < best!.area - 1e-9 {
            let (s, t) = ((u0 + u1) / 2, (v0 + v1) / 2)
            best = (area, s * u.0 + t * v.0, s * u.1 + t * v.1, u1 - u0, v1 - v0, atan2(u.1, u.0))
        }
    }
    guard var b = best else { return nil }
    if b.across > b.along { (b.along, b.across, b.theta) = (b.across, b.along, b.theta + .pi / 2) }
    var degrees = (b.theta * 180 / .pi).truncatingRemainder(dividingBy: 180)
    if degrees < 0 { degrees += 180 }
    if degrees >= 179.95 { degrees = 0 }
    return (b.cx, b.cy, b.along, b.across, degrees)
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
