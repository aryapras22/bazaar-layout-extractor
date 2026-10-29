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
    var ink = [Bool](repeating: false, count: n)
    for i in 0..<n {
        let r = Int(px.rgba[i * 4]), g = Int(px.rgba[i * 4 + 1]), b = Int(px.rgba[i * 4 + 2])
        let top = max(r, g, b)
        let sat = top == 0 ? 0 : (top - min(r, g, b)) * 255 / top
        ink[i] = sat < 40 && Int(gray[i]) < cut
    }
    return ink
}

func darkPixels(_ px: Pixels, below: Int) -> [Bool] {
    (0..<(px.width * px.height)).map { i in
        (299 * Int(px.rgba[i * 4]) + 587 * Int(px.rgba[i * 4 + 1]) + 114 * Int(px.rgba[i * 4 + 2])) / 1000 < below
    }
}

func outsideLayer(_ image: CGImage, _ px: Pixels, claimed: [Bool]) async -> [Item] {
    let (w, h) = (px.width, px.height)
    let n = w * h
    let mx = max(w, h)
    var items: [Item] = []

    let rawInk = inkMask(px)
    var ink = rawInk
    for i in 0..<n where claimed[i] { ink[i] = false }
    let scale = Double(mx) / 2000

    var textBoxes: [CGRect] = []
    let size = CGSize(width: w, height: h)
    if let found = try? await makeTextRequest().perform(on: image) {
        for o in found where o.confidence >= 0.5 {
            textBoxes.append(o.boundingBox.toImageCoordinates(size, origin: .upperLeft).insetBy(dx: -3, dy: -3))
        }
    }
    var inText = [Bool](repeating: false, count: n)
    for box in textBoxes { fillRect(&inText, box, w: w, h: h, value: true) }
    for i in 0..<n where inText[i] { ink[i] = false }

    let longest = max(5, Int((0.025 * Double(mx)).rounded()))
    var hs = longRuns(ink, w: w, h: h, minLen: longest, horizontal: true)
    var vs = longRuns(ink, w: w, h: h, minLen: longest, horizontal: false)
    let k = max(7, Int((0.004 * Double(mx)).rounded()) | 1)
    let opened = morph(morph(ink, w: w, h: h, rx: k / 2, ry: k / 2, erode: true),
                       w: w, h: h, rx: k / 2, ry: k / 2, erode: false)
    var thick = [Bool](repeating: false, count: n)
    var compact = [Bool](repeating: false, count: n)
    var pillars: [Region] = []
    for reg in components(opened, w: w, h: h, eight: true) {
        let long = max(reg.width, reg.height), short = min(reg.width, reg.height)
        if (long >= 4 * short && long >= longest) || reg.fill < 0.5 {
            for i in reg.pixels { thick[i] = true }
        } else {
            for i in reg.pixels { compact[i] = true }
            if reg.area >= Int(100 * scale * scale) { pillars.append(reg) }
        }
    }
    let compactNear = morph(compact, w: w, h: h, rx: 2, ry: 2, erode: false)
    for i in 0..<n where compactNear[i] { hs[i] = false; vs[i] = false }

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
    let minGap = Int(0.03 * Double(mx))
    for band in wallBands {
        var cov = [Bool](repeating: false, count: band.hi - band.lo + 1)
        let crossLimit = band.horizontal ? h : w
        let cLo = max(0, band.c0 - 2), cHi = min(crossLimit - 1, band.c1 + 2)
        for a in band.lo...band.hi {
            for c in cLo...cHi where rawInk[band.horizontal ? c * w + a : a * w + c] {
                cov[a - band.lo] = true
                break
            }
        }
        for (a, b) in gaps(cov, minLen: minGap) {
            let rect = band.horizontal
                ? CGRect(x: band.lo + a, y: band.c0, width: b - a + 1, height: band.c1 - band.c0 + 1)
                : CGRect(x: band.c0, y: band.lo + a, width: band.c1 - band.c0 + 1, height: b - a + 1)
            items.append(outsideItem("door", rect, review: fallback, reason: fallback ? "wall is a single line" : nil))
        }
    }

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

    var strokes = [Bool](repeating: false, count: n)
    for i in 0..<n { strokes[i] = hs[i] || vs[i] || thick[i] }
    let strokesNear = morph(strokes, w: w, h: h, rx: 3, ry: 3, erode: false)
    let pillarNear = morph(compact, w: w, h: h, rx: 4, ry: 4, erode: false)
    let hollowNear = morph(hollow, w: w, h: h, rx: 4, ry: 4, erode: false)
    var rest = [Bool](repeating: false, count: n)
    for i in 0..<n { rest[i] = ink[i] && !strokesNear[i] && !pillarNear[i] && !hollowNear[i] && !inText[i] }
    let restNear = morph(rest, w: w, h: h, rx: 2, ry: 2, erode: false)

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
            items.append(it)
        }
    }
    return items
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

func bridgeWalls(_ items: inout [Item], width: Int, height: Int, ruleCounts: inout [String: Int]) {
    let mx = Double(max(width, height))
    let openingGapTol = 0.03 * mx
    let dashGapTol = 0.03 * mx
    let bridgeGapTol = 0.015 * mx
    let touchTol = 0.005 * mx

    var removedIndices = Set<Int>()
    var addedItems: [Item] = []
    var dashedSpans: [[Int]] = []

    for horizontal in [true, false] {
        let wallIndices = items.indices.filter {
            items[$0].cls == "wall" && (items[$0].box[2] >= items[$0].box[3]) == horizontal
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
