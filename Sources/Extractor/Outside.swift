import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct Seg {
    var x0: Int, y0: Int, x1: Int, y1: Int
    let horizontal: Bool
    let confident: Bool
    var length: Int { horizontal ? x1 - x0 + 1 : y1 - y0 + 1 }
    var center: Int { horizontal ? (y0 + y1) / 2 : (x0 + x1) / 2 }
    var rect: CGRect { CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1) }
}

struct Band {
    var c0: Int, c1: Int
    var lo: Int, hi: Int
    var total: Int
    let horizontal: Bool
    let confident: Bool
    var center: Int { (c0 + c1) / 2 }
}

func segments(_ m: [Bool], w: Int, h: Int, horizontal: Bool, pad: Int, confident: Bool, minLength: Int) -> [Seg] {
    let merged = horizontal
        ? morph(m, w: w, h: h, rx: 0, ry: pad, erode: false)
        : morph(m, w: w, h: h, rx: pad, ry: 0, erode: false)
    var out: [Seg] = []
    for reg in components(merged, w: w, h: h, eight: true) {
        var x0 = w, y0 = h, x1 = 0, y1 = 0
        for i in reg.pixels where m[i] {
            let x = i % w, y = i / w
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
        guard x0 <= x1, y0 <= y1 else { continue }
        let seg = Seg(x0: x0, y0: y0, x1: x1, y1: y1, horizontal: horizontal, confident: confident)
        let stroke = horizontal ? y1 - y0 + 1 : x1 - x0 + 1
        if seg.length >= minLength, (confident || stroke >= 2) { out.append(seg) }
    }
    return out
}

func bands(_ segs: [Seg], tolerance: Int, minTotal: Int) -> [Band] {
    var out: [Band] = []
    for s in segs.sorted(by: { $0.center < $1.center }) {
        let lo = s.horizontal ? s.x0 : s.y0
        let hi = s.horizontal ? s.x1 : s.y1
        let c0 = s.horizontal ? s.y0 : s.x0
        let c1 = s.horizontal ? s.y1 : s.x1
        if let i = out.firstIndex(where: { $0.horizontal == s.horizontal && abs($0.center - s.center) <= tolerance }) {
            out[i].lo = min(out[i].lo, lo); out[i].hi = max(out[i].hi, hi)
            out[i].c0 = min(out[i].c0, c0); out[i].c1 = max(out[i].c1, c1)
            out[i].total += s.length
        } else {
            out.append(Band(c0: c0, c1: c1, lo: lo, hi: hi, total: s.length,
                            horizontal: s.horizontal, confident: s.confident))
        }
    }
    return out.filter { $0.total >= minTotal }
}

func gaps(_ cov: [Bool], minLen: Int) -> [(Int, Int)] {
    guard let first = cov.firstIndex(of: true), let last = cov.lastIndex(of: true) else { return [] }
    var out: [(Int, Int)] = []
    var start: Int?
    for i in first...last {
        if !cov[i], start == nil { start = i }
        if cov[i], let s = start {
            if i - s >= minLen { out.append((s, i - 1)) }
            start = nil
        }
    }
    return out
}

func inkMask(_ px: Pixels) -> [Bool] {
    let n = px.width * px.height
    var gray = [UInt8](repeating: 0, count: n)
    var hist = [Int](repeating: 0, count: 256)
    for i in 0..<n {
        let v = (299 * Int(px.rgba[i * 4]) + 587 * Int(px.rgba[i * 4 + 1]) + 114 * Int(px.rgba[i * 4 + 2])) / 1000
        gray[i] = UInt8(v)
        hist[v] += 1
    }
    var background = 255
    var acc = 0
    for v in 0..<256 {
        acc += hist[v]
        if acc * 2 >= n { background = v; break }
    }
    let cut = Int(Double(background) * 0.75)
    var channels = [(chroma: Int, sat: Int)](repeating: (0, 0), count: n)
    var darkGrey = 0, darkTinted = 0
    for i in 0..<n {
        let r = Int(px.rgba[i * 4]), g = Int(px.rgba[i * 4 + 1]), b = Int(px.rgba[i * 4 + 2])
        let top = max(r, g, b)
        let chroma = top - min(r, g, b)
        channels[i] = (chroma, top == 0 ? 0 : chroma * 255 / top)
        if gray[i] < 64 {
            if channels[i].sat < 40 { darkGrey += 1 } else if chroma < 24 { darkTinted += 1 }
        }
    }
    // Saturation is chroma over brightness, so a few levels of colour noise (pixel noise left after smoothing,
    // JPEG blocks) make near-black line pixels read as colours. Clean plans reject at most 0.72 of their
    // dark grey count that way, noisy and JPEG-damaged ones 5 or more; then chroma alone decides.
    let colourNoise = darkTinted >= 2 * max(darkGrey, 1)
    var ink = [Bool](repeating: false, count: n)
    for i in 0..<n {
        let (chroma, sat) = channels[i]
        ink[i] = (sat < 40 || (colourNoise && chroma < 30)) && Int(gray[i]) < cut
    }
    return ink
}

func darkPixels(_ px: Pixels, below: Int) -> [Bool] {
    (0..<(px.width * px.height)).map { i in
        (299 * Int(px.rgba[i * 4]) + 587 * Int(px.rgba[i * 4 + 1]) + 114 * Int(px.rgba[i * 4 + 2])) / 1000 < below
    }
}

func mergeWallBoxes(_ pieces: [Item], rule: String, reason: String) -> Item {
    var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
    var areaSum = 0
    var anyReview = false
    for p in pieces {
        x0 = min(x0, p.box[0])
        y0 = min(y0, p.box[1])
        x1 = max(x1, p.box[0] + p.box[2])
        y1 = max(y1, p.box[1] + p.box[3])
        areaSum += p.area
        if p.needsReview { anyReview = true }
    }
    let mergedBox = [x0, y0, x1 - x0, y1 - y0]
    return Item(
        cls: "wall", box: mergedBox, area: areaSum, fillRgb: [128, 128, 128],
        legendRgb: [128, 128, 128], text: "", id: nil, needsReview: anyReview,
        reason: anyReview ? "single line, not confirmed as a wall" : nil,
        fixRule: rule, fixReason: reason
    )
}

func bridgeWalls(_ items: inout [Item], page: Int, ruleCounts: inout [String: Int]) {
    let mx = Double(page)
    let openingGapTol = 0.03 * mx
    let dashGapTol = 0.03 * mx
    let bridgeGapTol = 0.015 * mx
    let touchTol = 0.005 * mx

    var removedIndices = Set<Int>()
    var addedItems: [Item] = []
    var dashedSpans: [[Int]] = []

    for horizontal in [true, false] {
        let wallIndices = items.indices.filter {
            items[$0].cls == "wall" && items[$0].segment == nil && (items[$0].box[2] >= items[$0].box[3]) == horizontal
        }
        func crossCenter(_ i: Int) -> Double { horizontal ? items[i].centerY : items[i].centerX }
        func stroke(_ i: Int) -> Double { Double(items[i].box[horizontal ? 3 : 2]) }
        func start(_ i: Int) -> Double { Double(items[i].box[horizontal ? 0 : 1]) }
        func end(_ i: Int) -> Double { start(i) + Double(items[i].box[horizontal ? 2 : 3]) }

        // Group collinear wall pieces when perpendicular offset stays under 0.75 of the wider stroke.
        var clusters: [[Int]] = []
        for idx in wallIndices.sorted(by: { stroke($0) > stroke($1) }) {
            if let ci = clusters.firstIndex(where: { members in
                let meanCross = members.map(crossCenter).reduce(0, +) / Double(members.count)
                let refStroke = members.map(stroke).max() ?? stroke(idx)
                return abs(crossCenter(idx) - meanCross) <= 0.75 * max(refStroke, stroke(idx))
            }) {
                clusters[ci].append(idx)
            } else {
                clusters.append([idx])
            }
        }

        for cluster in clusters where cluster.count >= 2 {
            let ordered = cluster.sorted { start($0) < start($1) }
            let maxClusterStroke = ordered.map(stroke).max() ?? 1.0
            let minClusterStroke = ordered.map(stroke).min() ?? 1.0
            var convertedToDoor = Set<Int>()

            if maxClusterStroke >= 2.0 * minClusterStroke {
                var pos = 0
                while pos < ordered.count {
                    let cur = ordered[pos]
                    if stroke(cur) >= 0.5 * maxClusterStroke {
                        pos += 1
                        continue
                    }
                    var endPos = pos
                    while endPos + 1 < ordered.count,
                          stroke(ordered[endPos + 1]) < 0.5 * maxClusterStroke,
                          start(ordered[endPos + 1]) - end(ordered[endPos]) <= openingGapTol
                    {
                        endPos += 1
                    }
                    if pos > 0, endPos + 1 < ordered.count {
                        let leftWall = ordered[pos - 1]
                        let rightWall = ordered[endPos + 1]
                        let minNeighbor = min(stroke(leftWall), stroke(rightWall))
                        let runIndices = Array(ordered[pos...endPos])
                        let maxThin = runIndices.map(stroke).max() ?? stroke(cur)
                        let leftGap = start(ordered[pos]) - end(leftWall)
                        let rightGap = start(rightWall) - end(ordered[endPos])
                        if maxThin < 0.5 * minNeighbor, leftGap <= openingGapTol, rightGap <= openingGapTol {
                            var rx0 = Int.max, ry0 = Int.max, rx1 = Int.min, ry1 = Int.min, rArea = 0
                            for ri in runIndices {
                                let b = items[ri].box
                                rx0 = min(rx0, b[0]); ry0 = min(ry0, b[1])
                                rx1 = max(rx1, b[0] + b[2]); ry1 = max(ry1, b[1] + b[3])
                                rArea += items[ri].area
                            }
                            let runBox = [rx0, ry0, rx1 - rx0, ry1 - ry0]
                            let runSpanLo = Double(horizontal ? rx0 : ry0)
                            let runSpanHi = Double(horizontal ? rx1 : ry1)
                            let runLen = max(1.0, runSpanHi - runSpanLo)
                            let zoneX0 = Double(rx0) - touchTol, zoneY0 = Double(ry0) - touchTol
                            let zoneX1 = Double(rx1) + touchTol, zoneY1 = Double(ry1) + touchTol

                            var bestFill: [Int]?
                            var bestScore = -Double.infinity
                            for fi in items.indices where items[fi].id == nil
                                && items[fi].cls != "wall" && items[fi].cls != "door" && items[fi].cls != "pillar"
                            {
                                let fb = items[fi].box
                                let fx0 = Double(fb[0]), fy0 = Double(fb[1])
                                let fx1 = fx0 + Double(fb[2]), fy1 = fy0 + Double(fb[3])
                                guard fx0 <= zoneX1, fx1 >= zoneX0, fy0 <= zoneY1, fy1 >= zoneY0 else { continue }
                                let fSpanLo = horizontal ? fx0 : fy0
                                let fSpanHi = horizontal ? fx1 : fy1
                                let overlap = max(0.0, min(runSpanHi, fSpanHi) - max(runSpanLo, fSpanLo))
                                guard overlap >= 0.25 * min(runLen, fSpanHi - fSpanLo) else { continue }
                                let rgb = items[fi].fillRgb
                                let nearWhite = rgb.count == 3
                                    && lab((UInt8(rgb[0]), UInt8(rgb[1]), UInt8(rgb[2]))).l > 90
                                let legendFill = rgb != [128, 128, 128]
                                let score = (nearWhite ? 10000.0 : (legendFill ? 5000.0 : 0.0)) + overlap
                                if score > bestScore {
                                    bestScore = score
                                    bestFill = fb
                                }
                            }

                            var door = Item(
                                cls: "door", box: runBox, area: rArea,
                                fillRgb: [128, 128, 128], legendRgb: [128, 128, 128],
                                text: "", id: nil, needsReview: true,
                                reason: "thin run between thicker wall pieces"
                            )
                            door.source = "thickness-transition"
                            door.fillBox = bestFill
                            door.fixRule = "thickness-transition"
                            door.fixReason = "stroke \(Int(maxThin)) between thicker collinear walls (\(Int(stroke(leftWall))), \(Int(stroke(rightWall))))"
                            addedItems.append(door)
                            ruleCounts["thickness-transition", default: 0] += 1
                            for ri in runIndices {
                                convertedToDoor.insert(ri)
                                removedIndices.insert(ri)
                            }
                        }
                    }
                    pos = endPos + 1
                }
            }

            let survivors = ordered.filter { !convertedToDoor.contains($0) }
            guard survivors.count >= 2 else { continue }

            // Partition survivors into runs of compatible stroke thickness before testing dashed or bridged runs.
            var runs: [[Int]] = [[survivors[0]]]
            for idx in survivors.dropFirst() {
                let prev = runs[runs.count - 1].last!
                let sA = stroke(prev), sB = stroke(idx)
                let gap = start(idx) - end(prev)
                if min(sA, sB) >= 0.5 * max(sA, sB), gap <= dashGapTol {
                    runs[runs.count - 1].append(idx)
                } else {
                    runs.append([idx])
                }
            }

            for run in runs where run.count >= 2 {
                var interGaps: [Double] = []
                for k in 1..<run.count {
                    interGaps.append(max(0.0, start(run[k]) - end(run[k - 1])))
                }
                let positiveGaps = interGaps.filter { $0 >= 1.0 }
                let isDashed: Bool
                if run.count >= 3, positiveGaps.count == interGaps.count,
                   let minG = positiveGaps.min(), let maxG = positiveGaps.max(),
                   minG > bridgeGapTol || run.allSatisfy({ items[$0].needsReview }),
                   maxG <= 2.0 * minG
                {
                    isDashed = true
                } else {
                    isDashed = false
                }

                if isDashed {
                    let merged = mergeWallBoxes(
                        run.map { items[$0] },
                        rule: "dashed-wall",
                        reason: "joined \(run.count) collinear dashed segments with regular gaps"
                    )
                    for ri in run { removedIndices.insert(ri) }
                    addedItems.append(merged)
                    dashedSpans.append(merged.box)
                    ruleCounts["dashed-wall", default: 0] += 1
                } else {
                    var sub: [Int] = [run[0]]
                    for k in 1..<run.count {
                        if interGaps[k - 1] <= bridgeGapTol {
                            sub.append(run[k])
                        } else {
                            if sub.count >= 2 {
                                let merged = mergeWallBoxes(
                                    sub.map { items[$0] },
                                    rule: "collinear-bridge",
                                    reason: "joined \(sub.count) collinear wall pieces"
                                )
                                for ri in sub { removedIndices.insert(ri) }
                                addedItems.append(merged)
                                ruleCounts["collinear-bridge", default: 0] += 1
                            }
                            sub = [run[k]]
                        }
                    }
                    if sub.count >= 2 {
                        let merged = mergeWallBoxes(
                            sub.map { items[$0] },
                            rule: "collinear-bridge",
                            reason: "joined \(sub.count) collinear wall pieces"
                        )
                        for ri in sub { removedIndices.insert(ri) }
                        addedItems.append(merged)
                        ruleCounts["collinear-bridge", default: 0] += 1
                    }
                }
            }
        }
    }

    if !dashedSpans.isEmpty {
        let pad = max(2, Int((0.004 * mx).rounded()))
        for idx in items.indices where items[idx].cls == "door" && items[idx].source != "thickness-transition" {
            let db = items[idx].box
            let overlapsDash = dashedSpans.contains { sb in
                let zx0 = sb[0] - pad, zy0 = sb[1] - pad
                let zx1 = sb[0] + sb[2] + pad, zy1 = sb[1] + sb[3] + pad
                return db[0] < zx1 && db[0] + db[2] > zx0 && db[1] < zy1 && db[1] + db[3] > zy0
            }
            if overlapsDash { removedIndices.insert(idx) }
        }
    }

    var updated: [Item] = []
    for idx in items.indices where !removedIndices.contains(idx) {
        updated.append(items[idx])
    }
    updated.append(contentsOf: addedItems)
    items = updated
}

/// A straight stroke that is neither horizontal nor vertical.
struct Slant {
    var x0: Double, y0: Double, x1: Double, y1: Double
    /// Stroke thickness: ink pixels per unit of length.
    var width: Double
    var length: Double { hypot(x1 - x0, y1 - y0) }
    var unit: (x: Double, y: Double) { ((x1 - x0) / length, (y1 - y0) / length) }
}

/// Slanted wall strokes need their own detector because `longRuns` only follows rows and columns. Each pass takes
/// the strongest line of the Hough accumulator, cuts the ink on it into runs at gaps, keeps the long dense ones
/// and removes their pixels, so a line that crosses another still finds the second one on the next pass.
/// Angles within `minDegrees` of an axis are skipped: that range is what `longRuns` already owns, and it is where
/// the wobble of a nominally straight wall would otherwise match.
func slantedStrokes(_ mask: [Bool], w: Int, h: Int, minLength: Double, gap: Double, minDegrees: Double = 10) -> [Slant] {
    var xs: [Double] = [], ys: [Double] = []
    for i in 0..<mask.count where mask[i] { xs.append(Double(i % w)); ys.append(Double(i / w)) }
    var angles: [Double] = []
    var a = 0.0
    while a < 180 {
        let m = a.truncatingRemainder(dividingBy: 90)
        if min(m, 90 - m) >= minDegrees { angles.append(a) }
        a += 0.5
    }
    let cosines = angles.map { cos($0 * .pi / 180) }, sines = angles.map { sin($0 * .pi / 180) }
    let diag = Int(hypot(Double(w), Double(h))) + 2
    let bins = 2 * diag + 1
    var votes = [Int32](repeating: 0, count: angles.count * bins)
    func vote(_ p: Int, _ sign: Int32) {
        for t in angles.indices {
            votes[t * bins + Int((xs[p] * cosines[t] + ys[p] * sines[t]).rounded()) + diag] += sign
        }
    }
    for p in xs.indices { vote(p, 1) }

    var alive = [Bool](repeating: true, count: xs.count)
    var found: [Slant] = []
    let floor = Int32(2 * minLength)
    for _ in 0..<300 {
        var best: Int32 = 0, bestT = 0, bestR = 0
        for t in angles.indices {
            let row = t * bins
            for r in 1..<(bins - 1) {
                let sum = votes[row + r - 1] + votes[row + r] + votes[row + r + 1]
                if sum > best { best = sum; bestT = t; bestR = r }
            }
        }
        if best < floor { break }
        let (nx, ny) = (cosines[bestT], sines[bestT])
        let offset = Double(bestR - diag)
        var near: [(s: Double, p: Int)] = []
        for p in xs.indices where alive[p] {
            if abs(xs[p] * nx + ys[p] * ny - offset) <= 2.5 { near.append((-xs[p] * ny + ys[p] * nx, p)) }
        }
        near.sort { $0.s < $1.s }
        var consumed = Set<Int>()
        var start = 0
        for i in 1...max(1, near.count) {
            guard i == near.count || near[i].s - near[i - 1].s > gap else { continue }
            let run = near[start..<i]
            start = i
            guard let first = run.first, let last = run.last else { continue }
            let length = last.s - first.s + 1
            guard length >= minLength, Double(run.count) / length >= 1.8 else { continue }
            func onLine(_ s: Double) -> (Double, Double) { (offset * nx - s * ny, offset * ny + s * nx) }
            let (p0, p1) = (onLine(first.s), onLine(last.s))
            found.append(Slant(x0: p0.0, y0: p0.1, x1: p1.0, y1: p1.1, width: Double(run.count) / length))
            for r in run { consumed.insert(r.p) }
        }
        for item in (consumed.isEmpty ? near.map(\.p) : Array(consumed)) {
            alive[item] = false
            vote(item, -1)
        }
    }
    return found
}

/// Moves each end of a slanted stroke outward while ink continues within one pixel of the line. Detection
/// runs on ink with the axis-aligned walls removed, so a stroke loses the stretch where it crosses or meets one.
/// The end stops `overlap` pixels past the last ink outside `axis`, which puts it on the centre line of the wall
/// it meets and not on the far side of it.
func extendedAlongInk(_ s: Slant, ink: [Bool], axis: [Bool], w: Int, h: Int, maxGap: Int, overlap: Double) -> Slant {
    var out = s
    let (ux, uy) = s.unit
    func hit(_ x: Double, _ y: Double, in mask: [Bool], excluding other: [Bool]? = nil) -> Bool {
        for m in -1...1 {
            let px = Int((x - Double(m) * uy).rounded()), py = Int((y + Double(m) * ux).rounded())
            if px >= 0, py >= 0, px < w, py < h, mask[py * w + px], !(other?[py * w + px] ?? false) { return true }
        }
        return false
    }
    func reach(from x: Double, _ y: Double, dx: Double, dy: Double) -> Double {
        var last = 0.0, anyLast = 0.0, misses = 0, k = 1.0
        while k <= s.length, misses <= maxGap {
            if hit(x + dx * k, y + dy * k, in: ink) {
                anyLast = k
                misses = 0
                if hit(x + dx * k, y + dy * k, in: ink, excluding: axis) { last = k }
            } else { misses += 1 }
            k += 1
        }
        return last == 0 ? 0 : min(anyLast, last + overlap)
    }
    let tail = reach(from: s.x0, s.y0, dx: -ux, dy: -uy)
    let head = reach(from: s.x1, s.y1, dx: ux, dy: uy)
    out.x0 -= ux * tail; out.y0 -= uy * tail
    out.x1 += ux * head; out.y1 += uy * head
    return out
}

/// Whether two segments cross when each is stretched by `stretch` of its length at both ends. A hairline X
/// loses the middle of one stroke to the other, so the pieces found no longer reach the crossing.
func slantsCross(_ a: Slant, _ b: Slant, stretch: Double = 0.5) -> Bool {
    func stretched(_ s: Slant) -> (Double, Double, Double, Double) {
        let (dx, dy) = (s.x1 - s.x0, s.y1 - s.y0)
        return (s.x0 - stretch * dx, s.y0 - stretch * dy, s.x1 + stretch * dx, s.y1 + stretch * dy)
    }
    let (a0, a1, a2, a3) = stretched(a), (b0, b1, b2, b3) = stretched(b)
    let (rx, ry, sx, sy) = (a2 - a0, a3 - a1, b2 - b0, b3 - b1)
    let denominator = rx * sy - ry * sx
    guard abs(denominator) > 1e-9 else { return false }
    let t = ((b0 - a0) * sy - (b1 - a1) * sx) / denominator
    let u = ((b0 - a0) * ry - (b1 - a1) * rx) / denominator
    return t > 0 && t < 1 && u > 0 && u < 1
}

/// Joins strokes that lie on one line, or on two lines closer than `separation` (a wall drawn as a double line),
/// when their extents overlap or leave a gap under `gap`.
func mergedSlants(_ input: [Slant], separation: Double, gap: Double) -> [Slant] {
    var slants = input.sorted { $0.length > $1.length }
    var i = 0
    while i < slants.count {
        var merged = false
        for j in (i + 1)..<max(i + 1, slants.count) {
            let a = slants[i], b = slants[j]
            let (ux, uy) = a.unit, (vx, vy) = b.unit
            guard abs(ux * vx + uy * vy) > cos(3 * Double.pi / 180) else { continue }
            func along(_ x: Double, _ y: Double) -> Double { x * ux + y * uy }
            func across(_ x: Double, _ y: Double) -> Double { -x * uy + y * ux }
            let aAcross = across((a.x0 + a.x1) / 2, (a.y0 + a.y1) / 2)
            let bAcross = across((b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2)
            let offset = abs(bAcross - aAcross)
            let aSpan = [along(a.x0, a.y0), along(a.x1, a.y1)].sorted()
            let bSpan = [along(b.x0, b.y0), along(b.x1, b.y1)].sorted()
            guard offset <= separation, bSpan[0] - aSpan[1] <= gap, aSpan[0] - bSpan[1] <= gap else { continue }
            let lo = min(aSpan[0], bSpan[0]), hi = max(aSpan[1], bSpan[1])
            let base = aAcross + (bAcross - aAcross) * b.length / (a.length + b.length)
            func point(_ s: Double) -> (Double, Double) { (s * ux - base * uy, s * uy + base * ux) }
            let (p0, p1) = (point(lo), point(hi))
            slants[i] = Slant(x0: p0.0, y0: p0.1, x1: p1.0, y1: p1.1, width: max(a.width, b.width) + offset)
            slants.remove(at: j)
            merged = true
            break
        }
        if !merged { i += 1 }
    }
    return slants
}

/// Slope of the dominant near-horizontal (or near-vertical) lines: the shear that makes the ink pile into the
/// fewest rows, found by trying slopes up to about 3 degrees. A page that is straight keeps slope 0 unless
/// another slope packs the ink at least 10% tighter, so clean plans never change.
func dominantTilt(_ mask: [Bool], w: Int, h: Int, horizontal: Bool) -> Double {
    var along: [Int32] = [], across: [Int32] = []
    for i in 0..<mask.count where mask[i] {
        along.append(Int32(horizontal ? i % w : i / w))
        across.append(Int32(horizontal ? i / w : i % w))
    }
    let (length, lines) = horizontal ? (w, h) : (h, w)
    let reach = Int(Double(length) * 0.053) + 1
    var counts = [Int32](repeating: 0, count: lines + 2 * reach + 1)
    func sharpness(_ slope: Double) -> Double {
        for i in counts.indices { counts[i] = 0 }
        for k in along.indices { counts[Int(across[k]) - Int((Double(along[k]) * slope).rounded()) + reach] += 1 }
        return counts.reduce(0.0) { $0 + Double($1) * Double($1) }
    }
    let straight = sharpness(0)
    var best = (slope: 0.0, score: straight)
    for step in -30...30 where step != 0 {
        let slope = tan(Double(step) * 0.1 * .pi / 180)
        let score = sharpness(slope)
        if score > best.score { best = (slope, score) }
    }
    return best.score >= 1.1 * straight ? best.slope : 0
}

/// Like `longRuns`, for lines that follow `tilt` (rise per step along them) instead of one row or column. A run
/// may wander one pixel off the ideal line, because a rotated 1 px line is not straight on the pixel grid.
func tiltedRuns(_ m: [Bool], w: Int, h: Int, minLen: Int, horizontal: Bool, tilt: Double) -> [Bool] {
    if tilt == 0 { return longRuns(m, w: w, h: h, minLen: minLen, horizontal: horizontal) }
    let (length, lines) = horizontal ? (w, h) : (h, w)
    let reach = Int(Double(length) * abs(tilt)) + 2
    var out = [Bool](repeating: false, count: m.count)
    for line in -reach..<(lines + reach) {
        var hits: [Int] = []
        var steps = 0
        for along in 0...length {
            var found: [Int] = []
            if along < length {
                let center = line + Int((Double(along) * tilt).rounded())
                for across in (center - 1)...(center + 1) where across >= 0 && across < lines {
                    let i = horizontal ? across * w + along : along * w + across
                    if m[i] { found.append(i) }
                }
            }
            if !found.isEmpty {
                hits += found
                steps += 1
                continue
            }
            if steps >= minLen { for i in hits { out[i] = true } }
            hits.removeAll(keepingCapacity: true)
            steps = 0
        }
    }
    return out
}
