import CoreGraphics
import Foundation

/// A circular arc of door-swing size: the path of a door leaf, drawn from the hinge (the circle centre).
struct Arc {
    let cx: Double, cy: Double, r: Double
    /// Radians, the arc runs from `from` to `to` counter-clockwise in image coordinates (y down).
    let from: Double, to: Double
    /// Whether a straight stroke lies along the radius at the arc's start or end: the leaf itself.
    let leafAtFrom: Bool, leafAtTo: Bool
    /// Box of the arc stroke together with its hinge, which is where the leaf stands.
    let rect: CGRect
    var bad: Double = 0
    /// Typical stroke width along the arc.
    var stroke: Double = 0
    /// Share of the swept sector, between the hinge and the arc, that holds ink. A real swing leaves it empty.
    var interior: Double = 0

    var span: Double { to - from }
    var score: Double { span * r }
}

/// Finds door-swing arcs in thin strokes. Each thin ink pixel votes for the centres of circles of radius r
/// that pass through it with its stroke direction as tangent, so a quarter circle collects about
/// a quarter of its circumference of votes at its hinge. Peaks are only candidates: each one is
/// checked by walking the whole circle, because a swing must span a quarter to a half circle,
/// leave the rest of the circle empty and carry a straight leaf along one end radius.
struct ArcFinder {
    let w: Int, h: Int
    let thin: [Bool]
    let minRadius: Int, maxRadius: Int

    private struct Voter { let index: Int32; let nx: Float; let ny: Float }

    private func voters() -> [Voter] {
        let half = 4
        var out: [Voter] = []
        for y in half..<(h - half) {
            for x in half..<(w - half) where thin[y * w + x] {
                var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
                for dy in -half...half {
                    let row = (y + dy) * w + x
                    for dx in -half...half where thin[row + dx] {
                        let fx = Double(dx), fy = Double(dy)
                        n += 1; sx += fx; sy += fy; sxx += fx * fx; syy += fy * fy; sxy += fx * fy
                    }
                }
                let mxx = sxx / n - (sx / n) * (sx / n)
                let myy = syy / n - (sy / n) * (sy / n)
                let mxy = sxy / n - (sx / n) * (sy / n)
                let trace = mxx + myy
                guard trace > 0 else { continue }
                let diff = sqrt((mxx - myy) * (mxx - myy) + 4 * mxy * mxy)
                guard diff / trace >= 0.6 else { continue }
                let tangent = 0.5 * atan2(2 * mxy, mxx - myy)
                out.append(Voter(index: Int32(y * w + x), nx: Float(-sin(tangent)), ny: Float(cos(tangent))))
            }
        }
        return out
    }

    func arcs() -> [Arc] {
        guard w > 8, h > 8 else { return [] }
        let voters = voters()
        var votes = [UInt16](repeating: 0, count: w * h)
        var touched: [Int32] = []
        var found: [Arc] = []
        var circles: [(x: Double, y: Double, r: Double)] = []
        var r = minRadius
        while r <= maxRadius {
            touched.removeAll(keepingCapacity: true)
            let fr = Float(r)
            for v in voters {
                let x = Int(v.index) % w, y = Int(v.index) / w
                for sign: Float in [-1, 1] {
                    let cx = x + Int((sign * fr * v.nx).rounded()), cy = y + Int((sign * fr * v.ny).rounded())
                    guard cx >= 0, cx < w, cy >= 0, cy < h else { continue }
                    let i = cy * w + cx
                    if votes[i] == 0 { touched.append(Int32(i)) }
                    votes[i] &+= 1
                }
            }
            let need = Int(0.5 * Double.pi * Double(r) / 2)
            var peaks: [(sum: Int, cx: Int, cy: Int)] = []
            for t in touched {
                let i = Int(t)
                guard votes[i] >= 2 else { continue }
                let cx = i % w, cy = i / w
                var sum = 0, isMax = true
                scan: for dy in -2...2 {
                    guard cy + dy >= 0, cy + dy < h else { continue }
                    for dx in -2...2 {
                        guard cx + dx >= 0, cx + dx < w else { continue }
                        let c = Int(votes[(cy + dy) * w + cx + dx])
                        sum += c
                        if c > Int(votes[i]) || (c == Int(votes[i]) && (dy < 0 || (dy == 0 && dx < 0))) { isMax = false; break scan }
                    }
                }
                if isMax, sum >= need { peaks.append((sum, cx, cy)) }
            }
            for t in touched { votes[Int(t)] = 0 }
            for p in peaks {
                switch verify(cx: p.cx, cy: p.cy, r: r) {
                case .arc(let arc): found.append(refined(arc))
                case .circle: circles.append((Double(p.cx), Double(p.cy), Double(r)))
                case .neither: break
                }
            }
            r += r < 24 ? 1 : (r < 48 ? 2 : 3)
        }
        // A chair or table ring is also matched by shifted circles that share a stretch of it.
        found.removeAll { arc in
            circles.contains { c in
                hypot(c.x - arc.cx, c.y - arc.cy) <= 0.6 * max(c.r, arc.r) && abs(c.r - arc.r) <= 0.4 * max(c.r, arc.r)
            }
        }
        return suppress(found)
    }

    private enum Verdict { case arc(Arc), circle, neither }

    /// Hough peaks are a pixel or two off, which a thin stroke on a small circle shows as drift.
    /// Try the neighbouring centres and radii and keep the one that sits best on the stroke.
    private func refined(_ arc: Arc) -> Arc {
        var best = arc
        for dy in -2...2 {
            for dx in -2...2 {
                for dr in -2...2 where (dx, dy, dr) != (0, 0, 0) {
                    let r = Int(arc.r) + dr
                    guard r >= minRadius, case .arc(let candidate) = verify(cx: Int(arc.cx) + dx, cy: Int(arc.cy) + dy, r: r) else { continue }
                    if candidate.bad < best.bad - 0.02 { best = candidate }
                }
            }
        }
        return best
    }

    /// Is thin ink within a pixel of this point?
    private func inked(_ x: Double, _ y: Double) -> Bool {
        let ix = Int(x.rounded()), iy = Int(y.rounded())
        guard ix >= 1, ix < w - 1, iy >= 1, iy < h - 1 else { return false }
        return thin[iy * w + ix] || thin[iy * w + ix - 1] || thin[iy * w + ix + 1]
            || thin[(iy - 1) * w + ix] || thin[(iy + 1) * w + ix]
    }

    private func verify(cx: Int, cy: Int, r: Int) -> Verdict {
        let n = max(24, Int((2 * Double.pi * Double(r)).rounded()))
        let step = 2 * Double.pi / Double(n)
        let fcx = Double(cx), fcy = Double(cy), fr = Double(r)
        var ring = [Bool](repeating: false, count: n)
        var count = 0
        for k in 0..<n {
            let a = Double(k) * step
            if inked(fcx + fr * cos(a), fcy + fr * sin(a)) { ring[k] = true; count += 1 }
        }
        if count >= n * 8 / 10 { return .circle }
        guard count >= n / 5, count <= n * 6 / 10 else { return .neither }
        // Bridge small gaps, then take the longest run around the circle.
        let bridge = max(2, n / 40)
        var closed = ring
        var k = 0
        while k < n {
            if ring[k] { k += 1; continue }
            var e = k
            while e < n, !ring[e] { e += 1 }
            if e - k <= bridge, k > 0, e < n { for j in k..<e { closed[j] = true } }
            k = e
        }
        guard let start = (0..<n).first(where: { !closed[$0] }) else { return .neither }
        var best = (len: 0, from: 0)
        var run = 0
        for j in 1...n {
            let idx = (start + j) % n
            if closed[idx] {
                run += 1
                if run > best.len { best = (run, (start + j - run + 1 + n) % n) }
            } else {
                run = 0
            }
        }
        let degrees = Double(best.len) * 360 / Double(n)
        guard degrees >= 70, degrees <= 195 else { return .neither }
        // Everything outside the run must be mostly empty, or this is a circle with a gap.
        var outside = 0
        for j in 0..<n where ring[j] {
            let offset = (j - best.from + n) % n
            if offset >= best.len { outside += 1 }
        }
        guard Double(outside) <= 0.15 * Double(n) else { return .neither }
        let from = Double(best.from) * step
        let to = from + Double(best.len - 1) * step
        let (badShare, stroke) = centred(cx: fcx, cy: fcy, r: fr, from: from, samples: best.len, step: step)
        guard badShare <= 0.6 else { return .neither }
        // One end of the arc stands on the leaf, which stops where the arc starts. The other end may
        // run into a wall, which does not stop there.
        let leafFrom = leaf(cx: fcx, cy: fcy, r: fr, angle: from) && !extends(cx: fcx, cy: fcy, r: fr, angle: from)
        let leafTo = leaf(cx: fcx, cy: fcy, r: fr, angle: to) && !extends(cx: fcx, cy: fcy, r: fr, angle: to)
        guard leafFrom || leafTo else { return .neither }
        var x0 = fcx, y0 = fcy, x1 = fcx, y1 = fcy
        for j in 0..<best.len {
            let a = from + Double(j) * step
            let px = fcx + fr * cos(a), py = fcy + fr * sin(a)
            x0 = min(x0, px); x1 = max(x1, px); y0 = min(y0, py); y1 = max(y1, py)
        }
        return .arc(Arc(cx: fcx, cy: fcy, r: fr, from: from, to: to, leafAtFrom: leafFrom, leafAtTo: leafTo,
                   rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), bad: badShare, stroke: stroke, interior: interiorShare(cx: fcx, cy: fcy, r: fr, from: from, samples: best.len, step: step)))
    }

    /// The stroke must sit on the circle along its whole length with a steady width. A thick stroke on a small
    /// circle lets a circle with the wrong centre touch the ink over a long run, but its ink then drifts to one
    /// side, and a line crossing the ring at a slant makes the stroke swell.
    private func centred(cx: Double, cy: Double, r: Double, from: Double, samples: Int, step: Double) -> (bad: Double, stroke: Double) {
        let reach = 4
        let tolerance = max(1.0, 0.06 * r)
        var offsets: [Double] = [], widths: [Double] = []
        for j in 0..<samples {
            let a = from + Double(j) * step
            var sum = 0.0, count = 0.0
            for t in -reach...reach {
                let d = r + Double(t)
                let ix = Int((cx + d * cos(a)).rounded()), iy = Int((cy + d * sin(a)).rounded())
                guard ix >= 0, ix < w, iy >= 0, iy < h, thin[iy * w + ix] else { continue }
                sum += Double(t); count += 1
            }
            guard count > 0 else { continue }
            offsets.append(sum / count); widths.append(count)
        }
        guard !widths.isEmpty else { return (1, 0) }
        let typical = widths.sorted()[widths.count / 2]
        var bad = 0
        for k in offsets.indices where abs(offsets[k]) > tolerance || widths[k] > 1.6 * typical + 1 { bad += 1 }
        return (Double(bad) / Double(offsets.count), typical)
    }

    private func interiorShare(cx: Double, cy: Double, r: Double, from: Double, samples: Int, step: Double) -> Double {
        var hits = 0, total = 0
        for factor in [0.35, 0.55, 0.75] {
            for j in stride(from: 0, to: samples, by: 2) {
                let a = from + Double(j) * step
                let ix = Int((cx + factor * r * cos(a)).rounded()), iy = Int((cy + factor * r * sin(a)).rounded())
                guard ix >= 0, ix < w, iy >= 0, iy < h else { continue }
                total += 1
                if thin[iy * w + ix] { hits += 1 }
            }
        }
        return total == 0 ? 1 : Double(hits) / Double(total)
    }

    /// A door leaf stops where its arc starts. A line that goes on past the arc end is a wall or a table edge.
    private func extends(cx: Double, cy: Double, r: Double, angle: Double) -> Bool {
        var hits = 0, total = 0
        var d = 1.15 * r
        while d <= 1.5 * r {
            total += 1
            if inked(cx + d * cos(angle), cy + d * sin(angle)) { hits += 1 }
            d += 1
        }
        return total > 0 && Double(hits) >= 0.8 * Double(total)
    }

    /// A straight stroke from the hinge to the arc end.
    private func leaf(cx: Double, cy: Double, r: Double, angle: Double) -> Bool {
        let steps = Int(r * 0.7)
        guard steps >= 3 else { return false }
        var hits = 0
        for s in 0..<steps {
            let d = r * (0.15 + 0.75 * Double(s) / Double(steps))
            if inked(cx + d * cos(angle), cy + d * sin(angle)) { hits += 1 }
        }
        return Double(hits) >= 0.85 * Double(steps)
    }

    /// The same arc is found at neighbouring radii and centres; keep the longest of each cluster.
    private func suppress(_ arcs: [Arc]) -> [Arc] {
        var kept: [Arc] = []
        for arc in arcs.sorted(by: { $0.score > $1.score }) {
            let duplicate = kept.contains { k in
                hypot(k.cx - arc.cx, k.cy - arc.cy) <= 0.35 * max(k.r, arc.r) && abs(k.r - arc.r) <= 0.3 * max(k.r, arc.r)
            }
            if !duplicate { kept.append(arc) }
        }
        return kept
    }
}
