import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Seat layer: what is left once walls, columns and text are set aside, grouped by shape. Tables with
/// chairs, audience seating and stairs all arrive here as `object`; the judge decides which are seats.
func seatLayer(_ s: InkScan, hollow: [Bool]) -> [Item] {
    let (w, h, n, mx, scale) = (s.w, s.h, s.n, s.mx, s.scale)
    let (ink, inText, hs, vs, thick, compact) = (s.ink, s.inText, s.hs, s.vs, s.thick, s.compact)
    var items: [Item] = []

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
