import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Tunables (values come from synthetic layouts, adjust on real plans)

let gateDeltaE = 12.0
let marginDeltaE = 1.5
let legendWarnDeltaE = 10.0
let minSolidity = 0.85
let minColorCover = 0.4

enum ExtractError: Error { case unreadable(URL), noLegend }

// MARK: - Color

struct Lab { var l, a, b: Double }

func lab(_ c: (UInt8, UInt8, UInt8)) -> Lab {
    func lin(_ v: UInt8) -> Double {
        let s = Double(v) / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    let (r, g, b) = (lin(c.0), lin(c.1), lin(c.2))
    let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
    let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
    func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
    let (fx, fy, fz) = (f(x), f(y), f(z))
    return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
}

func distance(_ p: Lab, _ q: Lab) -> Double {
    sqrt(pow(p.l - q.l, 2) + pow(p.a - q.a, 2) + pow(p.b - q.b, 2))
}

// MARK: - Pixels

struct Pixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (rgba[i], rgba[i + 1], rgba[i + 2])
    }
}

func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw ExtractError.unreadable(url) }
    return image
}

func pixels(of image: CGImage) -> Pixels {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return Pixels(width: w, height: h, rgba: data)
}

// MARK: - Masks and morphology

func morph(_ src: [Bool], w: Int, h: Int, rx: Int, ry: Int, erode: Bool) -> [Bool] {
    func pass(_ a: [Bool], lines: Int, length: Int, r: Int, step: Int, lineStep: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: a.count)
        var prefix = [Int32](repeating: 0, count: length + 1)
        for line in 0..<lines {
            let base = line * lineStep
            for i in 0..<length { prefix[i + 1] = prefix[i] + (a[base + i * step] ? 1 : 0) }
            for i in 0..<length {
                if erode {
                    guard i - r >= 0, i + r < length else { continue }
                    if prefix[i + r + 1] - prefix[i - r] == Int32(2 * r + 1) { out[base + i * step] = true }
                } else {
                    let lo = max(0, i - r), hi = min(length - 1, i + r)
                    if prefix[hi + 1] - prefix[lo] > 0 { out[base + i * step] = true }
                }
            }
        }
        return out
    }
    let rows = pass(src, lines: h, length: w, r: rx, step: 1, lineStep: w)
    return pass(rows, lines: w, length: h, r: ry, step: w, lineStep: 1)
}

func longRuns(_ m: [Bool], w: Int, h: Int, minLen: Int, horizontal: Bool) -> [Bool] {
    var out = [Bool](repeating: false, count: m.count)
    let lines = horizontal ? h : w
    let length = horizontal ? w : h
    let step = horizontal ? 1 : w
    let lineStep = horizontal ? w : 1
    for line in 0..<lines {
        let base = line * lineStep
        var run = 0
        for i in 0...length {
            if i < length, m[base + i * step] { run += 1; continue }
            if run >= minLen { for j in (i - run)..<i { out[base + j * step] = true } }
            run = 0
        }
    }
    return out
}

func pairs(_ m: [Bool], ink: [Bool], w: Int, h: Int, dmin: Int, dmax: Int, horizontal: Bool) -> [Bool] {
    var keep = [Bool](repeating: false, count: m.count)
    let step = horizontal ? w : 1
    let limit = horizontal ? h : w
    for i in 0..<m.count where m[i] {
        let pos = horizontal ? i / w : i % w
        search: for d in dmin...dmax {
            for sign in stride(from: -1, through: 1, by: 2) {
                let p = pos + sign * d
                guard p >= 0, p < limit else { continue }
                let partner = i + sign * d * step
                let mid = i + sign * (d / 2) * step
                if m[partner], !ink[mid] { keep[i] = true; break search }
            }
        }
    }
    let grown = horizontal
        ? morph(keep, w: w, h: h, rx: 0, ry: dmax, erode: false)
        : morph(keep, w: w, h: h, rx: dmax, ry: 0, erode: false)
    var out = keep
    for i in 0..<m.count where grown[i] && m[i] { out[i] = true }
    return out
}

struct Region {
    var minX: Int, minY: Int, maxX: Int, maxY: Int
    var pixels: [Int]
    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
    var area: Int { pixels.count }
    var fill: Double { Double(pixels.count) / Double(width * height) }
}

func components(_ mask: [Bool], w: Int, h: Int, eight: Bool) -> [Region] {
    var seen = [Bool](repeating: false, count: mask.count)
    var stack: [Int] = []
    var found: [Region] = []
    func push(_ j: Int) {
        if mask[j], !seen[j] { seen[j] = true; stack.append(j) }
    }
    for start in 0..<mask.count where mask[start] && !seen[start] {
        seen[start] = true
        stack.append(start)
        var reg = Region(minX: w, minY: h, maxX: 0, maxY: 0, pixels: [])
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            reg.pixels.append(i)
            reg.minX = min(reg.minX, x); reg.maxX = max(reg.maxX, x)
            reg.minY = min(reg.minY, y); reg.maxY = max(reg.maxY, y)
            if x > 0 { push(i - 1) }
            if x < w - 1 { push(i + 1) }
            if y > 0 { push(i - w) }
            if y < h - 1 { push(i + w) }
            if eight {
                if x > 0, y > 0 { push(i - w - 1) }
                if x < w - 1, y > 0 { push(i - w + 1) }
                if x > 0, y < h - 1 { push(i + w - 1) }
                if x < w - 1, y < h - 1 { push(i + w + 1) }
            }
        }
        found.append(reg)
    }
    return found
}

// Text inside a tile leaves holes in its color mask. Small enclosed holes are filled so the tile keeps
// its full shape. Three things must stay open: a large enclosure such as a wall frame, the inside of a
// neighbouring tile that a dark outline rings (that would turn it into a tile of the dark class),
// and a thin seam between two tiles of the same color (filling it would merge them).
func fillHoles(_ mask: [Bool], w: Int, h: Int, maxHole: Int, seamLength: Int) -> [Bool] {
    var out = mask
    var seen = [Bool](repeating: false, count: mask.count)
    var stack: [Int] = []
    for start in 0..<mask.count where !mask[start] && !seen[start] {
        seen[start] = true
        stack.append(start)
        var hole: [Int] = []
        var open = false
        var x0 = w, x1 = 0, y0 = h, y1 = 0
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x == 0 || y == 0 || x == w - 1 || y == h - 1 { open = true }
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            if hole.count <= maxHole { hole.append(i) }
            if x > 0, !mask[i - 1], !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
            if x < w - 1, !mask[i + 1], !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
            if y > 0, !mask[i - w], !seen[i - w] { seen[i - w] = true; stack.append(i - w) }
            if y < h - 1, !mask[i + w], !seen[i + w] { seen[i + w] = true; stack.append(i + w) }
        }
        let thin = min(x1 - x0, y1 - y0) + 1 <= 2 && max(x1 - x0, y1 - y0) + 1 >= seamLength
        if !open, hole.count <= maxHole, !thin { for i in hole { out[i] = true } }
    }
    return out
}

// Convex hull of the pixel corners of a set of pixels, by Andrew's monotone chain over each row's extremes.
func convexHull(_ pixels: [Int], w: Int, minY: Int, height: Int) -> [(Double, Double)] {
    var lo = [Int](repeating: Int.max, count: height), hi = [Int](repeating: -1, count: height)
    for i in pixels {
        let row = i / w - minY
        lo[row] = min(lo[row], i % w); hi[row] = max(hi[row], i % w)
    }
    var points: [(Double, Double)] = []
    for row in 0..<height where hi[row] >= 0 {
        let y = Double(minY + row)
        for x in [Double(lo[row]) - 0.5, Double(hi[row]) + 0.5] {
            points.append((x, y - 0.5)); points.append((x, y + 0.5))
        }
    }
    points.sort { ($0.0, $0.1) < ($1.0, $1.1) }
    func cross(_ o: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
        (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
    }
    var hull: [(Double, Double)] = []
    for p in points {
        while hull.count >= 2, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
        hull.append(p)
    }
    let lowerCount = hull.count + 1
    for p in points.reversed().dropFirst() {
        while hull.count >= lowerCount, cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
        hull.append(p)
    }
    hull.removeLast()
    return hull
}

func polygonArea(_ poly: [(Double, Double)]) -> Double {
    var twice = 0.0
    for i in poly.indices {
        let a = poly[i], b = poly[(i + 1) % poly.count]
        twice += a.0 * b.1 - b.0 * a.1
    }
    return abs(twice) / 2
}

// Area over convex hull area: about 1 for a square or a triangle, low for a ragged blob.
// Box fill would reject the diagonal tiles, whose box is half empty.
func solidity(_ reg: Region, w: Int) -> Double {
    let hullArea = polygonArea(convexHull(reg.pixels, w: w, minY: reg.minY, height: reg.height))
    return hullArea > 0 ? Double(reg.area) / hullArea : 0
}

// Douglas-Peucker on a closed polygon: split at the point farthest from the first, then drop
// vertices that lie within epsilon of the chord. A hull built from pixel rows is a staircase
// along a slanted edge, and this reduces each edge to its two ends.
func simplify(_ poly: [(Double, Double)], epsilon: Double) -> [(Double, Double)] {
    guard poly.count > 3 else { return poly }
    func offset(_ p: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let dx = b.0 - a.0, dy = b.1 - a.1
        let len = (dx * dx + dy * dy).squareRoot()
        if len == 0 { return ((p.0 - a.0) * (p.0 - a.0) + (p.1 - a.1) * (p.1 - a.1)).squareRoot() }
        return abs(dx * (a.1 - p.1) - (a.0 - p.0) * dy) / len
    }
    func keep(_ pts: [(Double, Double)]) -> [(Double, Double)] {
        guard pts.count > 2 else { return Array(pts.dropLast()) }
        var far = 0, farOffset = 0.0
        for i in 1..<(pts.count - 1) {
            let d = offset(pts[i], pts[0], pts[pts.count - 1])
            if d > farOffset { far = i; farOffset = d }
        }
        if farOffset <= epsilon { return [pts[0]] }
        return keep(Array(pts[...far])) + keep(Array(pts[far...]))
    }
    let half = poly.indices.max { offset(poly[$0], poly[0], poly[0]) < offset(poly[$1], poly[0], poly[0]) }!
    return keep(Array(poly[...half])) + keep(Array(poly[half...]) + [poly[0]])
}

func fillRect(_ mask: inout [Bool], _ r: CGRect, w: Int, h: Int, value: Bool) {
    let x0 = max(0, Int(r.minX.rounded(.down))), x1 = min(w - 1, Int(r.maxX.rounded(.up)))
    let y0 = max(0, Int(r.minY.rounded(.down))), y1 = min(h - 1, Int(r.maxY.rounded(.up)))
    guard x0 <= x1, y0 <= y1 else { return }
    for y in y0...y1 { for x in x0...x1 { mask[y * w + x] = value } }
}

// MARK: - Vision text

// Vision reads some Latin letters, and the digit 3, as Cyrillic lookalikes, in the legend as well as on tiles.
let cyrillicLookalikes: [Character: Character] = [
    "\u{0410}": "A", "\u{0412}": "B", "\u{0421}": "C", "\u{0415}": "E", "\u{041D}": "H",
    "\u{041A}": "K", "\u{041E}": "O", "\u{0425}": "X", "\u{0417}": "3",
]

func foldLookalikes(_ s: String) -> String {
    String(s.map { cyrillicLookalikes[$0] ?? $0 })
}

func makeTextRequest() -> RecognizeTextRequest {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    return request
}

func readLabel(_ image: CGImage, in rect: CGRect) async throws -> String? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let crop = image.cropping(to: rect.insetBy(dx: 4, dy: 4).intersection(bounds)) else { return nil }
    let found = try await makeTextRequest().perform(on: crop)
    return found.max { $0.confidence < $1.confidence }?.transcript
}

func cleanLabel(_ raw: String) -> String? {
    let s = Array(foldLookalikes(raw.uppercased()).filter { !$0.isWhitespace })
    guard let firstDigit = s.firstIndex(where: { $0.isNumber }), (1...3).contains(firstDigit) else { return nil }
    let head = s[..<firstDigit]
    guard head.allSatisfy({ $0.isLetter }) else { return nil }
    let tail = s[firstDigit...].map { c -> Character in
        switch c {
        case "I", "L", "|": return "1"
        case "O": return "0"
        default: return c
        }
    }
    guard tail.allSatisfy({ $0.isNumber }) else { return nil }
    return String(head) + String(tail)
}

// MARK: - Output

struct LegendEntry: Codable {
    var label: String
    var colors: [[Int]]
    var prefix: String?
}

struct Item: Codable {
    var cls: String
    var box: [Int]
    var area: Int
    var fillRgb: [Int]
    var legendRgb: [Int]
    var text: String
    var id: String?
    var needsReview: Bool
    var reason: String?
    var polygon: [[Int]]?

    enum CodingKeys: String, CodingKey {
        case cls = "class", box, area, fillRgb = "fill_rgb", legendRgb = "legend_rgb", text, id
        case needsReview = "needs_review", reason, polygon
    }

    var rect: CGRect { CGRect(x: box[0], y: box[1], width: box[2], height: box[3]) }

    // The notebook render cell indexes it["id"], so a missing ID must be an explicit null.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cls, forKey: .cls)
        try c.encode(box, forKey: .box)
        try c.encode(area, forKey: .area)
        try c.encode(fillRgb, forKey: .fillRgb)
        try c.encode(legendRgb, forKey: .legendRgb)
        try c.encode(text, forKey: .text)
        try c.encode(id, forKey: .id)
        try c.encode(needsReview, forKey: .needsReview)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(polygon, forKey: .polygon)
    }
}

struct Report: Codable {
    var itemsPerClass: [String: Int]
    var idsRead: Int
    var itemsWithoutId: Int
    var duplicateIds: [String]
    var gapsInNumbering: [String: [Int]]
    var maxNumberPerPrefix: [String: Int]

    enum CodingKeys: String, CodingKey {
        case itemsPerClass = "items_per_class", idsRead = "ids_read", itemsWithoutId = "items_without_id"
        case duplicateIds = "duplicate_ids", gapsInNumbering = "gaps_in_numbering", maxNumberPerPrefix = "max_number_per_prefix"
    }
}

struct ImageInfo: Codable {
    var width: Int
    var height: Int
    var unit = "px"
    var origin = "top-left"
}

struct Result: Codable {
    var image: ImageInfo
    var legend: [LegendEntry]
    var items: [Item]
    var report: Report
}

func report(_ items: [Item]) -> Report {
    let ids = items.compactMap(\.id)
    var nums: [String: Set<Int>] = [:]
    for id in ids {
        guard let split = id.firstIndex(where: \.isNumber), let n = Int(id[split...]) else { continue }
        nums[String(id[..<split]), default: []].insert(n)
    }
    let gaps = nums.compactMapValues { s -> [Int]? in
        guard let hi = s.max(), hi >= 1 else { return nil }
        let missing = Set(1...hi).subtracting(s).sorted()
        return missing.isEmpty ? nil : missing
    }
    return Report(
        itemsPerClass: Dictionary(items.map { ($0.cls, 1) }, uniquingKeysWith: +),
        idsRead: ids.count,
        itemsWithoutId: items.count - ids.count,
        duplicateIds: Dictionary(ids.map { ($0, 1) }, uniquingKeysWith: +).filter { $0.value > 1 }.keys.sorted(),
        gapsInNumbering: gaps,
        maxNumberPerPrefix: nums.mapValues { $0.max()! })
}

func writeOverlay(_ layout: CGImage, items: [Item], to url: URL) {
    let (w, h) = (layout.width, layout.height)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(layout, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setLineWidth(2)
    for item in items {
        ctx.setStrokeColor(item.id == nil ? CGColor(red: 0, green: 0, blue: 1, alpha: 1) : CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.stroke(CGRect(x: item.box[0], y: h - item.box[1] - item.box[3], width: item.box[2], height: item.box[3]))
    }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

func box(_ r: CGRect) -> [Int] {
    [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)]
}

// Layer 2 has no legend color, so these items carry a neutral gray.
func outsideItem(_ kind: String, _ rect: CGRect, review: Bool, reason: String?) -> Item {
    Item(cls: kind, box: box(rect), area: Int(rect.width * rect.height), fillRgb: [128, 128, 128],
         legendRgb: [128, 128, 128], text: "", id: nil, needsReview: review, reason: reason)
}

// MARK: - Layer 1: legend

struct LegendClass {
    let name: String
    let rgb: (UInt8, UInt8, UInt8)
    let lab: Lab
}

func boothPrefix(_ name: String) -> String? {
    let t = name.lowercased()
    for prefix in ["large booth ", "booth "] where t.hasPrefix(prefix) {
        return String(t.dropFirst(prefix.count)).uppercased()
    }
    return nil
}

func isNearWhite(_ c: (UInt8, UInt8, UInt8)) -> Bool {
    (255 - Int(c.0)) + (255 - Int(c.1)) + (255 - Int(c.2)) < 30
}

func readLegend(_ image: CGImage) async throws -> [LegendClass] {
    let px = pixels(of: image)
    let size = CGSize(width: image.width, height: image.height)
    var classes: [LegendClass] = []
    for observation in try await makeTextRequest().perform(on: image) {
        let name = foldLookalikes(observation.transcript).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              !classes.contains(where: { $0.name.lowercased() == name.lowercased() })
        else { continue }
        let box = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
        let y = Int(box.midY)
        guard y >= 0, y < px.height else { continue }
        var x = Int(box.minX) - 1
        while x > 8, isNearWhite(px.rgb(x, y)) { x -= 1 }
        guard x > 8 else { continue }
        let color = px.rgb(x - 8, y)
        classes.append(LegendClass(name: name, rgb: color, lab: lab(color)))
    }
    return classes
}

func legendWarnings(_ classes: [LegendClass]) -> [String] {
    var out: [String] = []
    for i in 0..<classes.count {
        if classes[i].lab.l > 95 { out.append("\"\(classes[i].name)\" is nearly white, so it can merge with the background") }
        if classes[i].lab.l < 8 { out.append("\"\(classes[i].name)\" is nearly black, so it can merge with outlines and text") }
        for j in (i + 1)..<max(i + 1, classes.count) {
            let d = distance(classes[i].lab, classes[j].lab)
            if d < legendWarnDeltaE {
                out.append("\"\(classes[i].name)\" and \"\(classes[j].name)\" are only \(String(format: "%.1f", d)) apart in color, matches between them are flagged")
            }
        }
    }
    return out
}

func classify(_ px: Pixels, legend: [LegendClass]) -> [Int16] {
    var cache: [UInt32: Int16] = [:]
    var grid = [Int16](repeating: -1, count: px.width * px.height)
    for i in 0..<grid.count {
        let (r, g, b) = (px.rgba[i * 4], px.rgba[i * 4 + 1], px.rgba[i * 4 + 2])
        let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        if let hit = cache[key] { grid[i] = hit; continue }
        let p = lab((r, g, b))
        var best: Int16 = -1
        var bestDistance = gateDeltaE
        for (j, entry) in legend.enumerated() {
            let d = distance(p, entry.lab)
            if d < bestDistance { bestDistance = d; best = Int16(j) }
        }
        cache[key] = best
        grid[i] = best
    }
    return grid
}

func medianRGB(_ px: Pixels, _ indices: [Int]) -> (UInt8, UInt8, UInt8) {
    let step = max(1, indices.count / 2000)
    var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
    for k in stride(from: 0, to: indices.count, by: step) {
        let i = indices[k]
        rs.append(px.rgba[i * 4]); gs.append(px.rgba[i * 4 + 1]); bs.append(px.rgba[i * 4 + 2])
    }
    rs.sort(); gs.sort(); bs.sort()
    return (rs[rs.count / 2], gs[gs.count / 2], bs[bs.count / 2])
}

// Dark outlines split the plan into faces. A tile's polygon is the hull of the face that holds most of
// its color pixels, so a sloped booth keeps its slanted edges. The polygon lies inside the outline.
func tilePolygon(_ reg: Region, rect: CGRect, faces: [Region], faceOf: [Int32], w: Int, epsilon: Double) -> [[Int]]? {
    var votes: [Int32: Int] = [:]
    for i in reg.pixels where faceOf[i] >= 0 { votes[faceOf[i], default: 0] += 1 }
    guard let best = votes.max(by: { $0.value < $1.value })?.key else { return nil }
    let face = faces[Int(best)]
    let bounds = CGRect(x: face.minX, y: face.minY, width: face.width, height: face.height)
    guard rect.insetBy(dx: -6, dy: -6).contains(bounds) else { return nil }
    let poly = simplify(convexHull(face.pixels, w: w, minY: face.minY, height: face.height), epsilon: epsilon)
    return poly.count >= 3 ? poly.map { [Int($0.0.rounded()), Int($0.1.rounded())] } : nil
}

func legendLayer(_ image: CGImage, _ px: Pixels, legend: [LegendClass]) async throws -> [Item] {
    let (w, h) = (px.width, px.height)
    let scale = Double(max(w, h)) / 2000
    let r = max(1, Int((3 * scale).rounded()))
    let minArea = Int(400 * scale * scale)
    let maxHole = Int(2000 * scale * scale)
    let seamLength = Int(20 * scale)
    let canvas = CGRect(x: 0, y: 0, width: w, height: h)
    let grid = classify(px, legend: legend)
    // Closing one pixel of gap keeps a broken outline from merging two tiles into one face.
    let outlines = morph(darkPixels(px, below: 60), w: w, h: h, rx: 1, ry: 1, erode: false)
    let faces = components(outlines.map { !$0 }, w: w, h: h, eight: false)
    var faceOf = [Int32](repeating: -1, count: w * h)
    for (j, face) in faces.enumerated() { for i in face.pixels { faceOf[i] = Int32(j) } }

    struct Found {
        var item: Item
        let cls: Int
        let label: String?
        let raw: String?
    }
    var found: [Found] = []

    for (k, entry) in legend.enumerated() {
        let whole = fillHoles(grid.map { $0 == Int16(k) }, w: w, h: h, maxHole: maxHole, seamLength: seamLength)
        let mask = morph(whole, w: w, h: h, rx: r, ry: r, erode: true)
        for reg in components(mask, w: w, h: h, eight: false) {
            guard reg.area >= minArea, solidity(reg, w: w) >= minSolidity else { continue }
            let rect = CGRect(x: reg.minX - r, y: reg.minY - r, width: reg.width + 2 * r, height: reg.height + 2 * r)
                .intersection(canvas)
            var reasons: [String] = []

            let median = lab(medianRGB(px, reg.pixels))
            let ranked = legend.enumerated()
                .map { (index: $0.offset, d: distance(median, $0.element.lab)) }
                .sorted { $0.d < $1.d }
            if ranked.count > 1, ranked[1].d - ranked[0].d < marginDeltaE {
                reasons.append("color is nearly as close to \"\(legend[ranked[1].index].name)\"")
            }
            if ranked[0].index != k {
                reasons.append("median color is closer to \"\(legend[ranked[0].index].name)\"")
            }

            // The eroded area undercounts the tile, so count the class pixels inside the final box.
            var tileArea = 0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) where grid[y * w + x] == Int16(k) { tileArea += 1 }
            }

            // A hollow outline that hole filling closed (a door swing, say) holds little of the class color.
            guard Double(tileArea) >= minColorCover * rect.width * rect.height else { continue }

            let raw = try await readLabel(image, in: rect)
            let label = raw.flatMap { cleanLabel($0) }
            let rgb = [Int(entry.rgb.0), Int(entry.rgb.1), Int(entry.rgb.2)]
            found.append(Found(
                item: Item(
                    cls: entry.name, box: box(rect), area: tileArea, fillRgb: rgb, legendRgb: rgb,
                    text: raw ?? "", id: label, needsReview: !reasons.isEmpty,
                    reason: reasons.isEmpty ? nil : reasons.joined(separator: "; "),
                    polygon: tilePolygon(reg, rect: rect, faces: faces, faceOf: faceOf, w: w, epsilon: 2 * scale)),
                cls: k, label: label, raw: raw))
        }
    }

    // A class counts as labelled when at least half of its regions carry a readable id.
    // Unlabelled classes (stage, exit, blocked) are not flagged for missing text.
    var labelled = Set<Int>()
    for k in legend.indices {
        let members = found.filter { $0.cls == k }
        let withLabel = members.filter { $0.label != nil }.count
        if !members.isEmpty, withLabel * 2 >= members.count { labelled.insert(k) }
    }
    var counts: [String: Int] = [:]
    for f in found where labelled.contains(f.cls) {
        if let id = f.label { counts[id, default: 0] += 1 }
    }

    var items: [Item] = []
    for var f in found {
        var reasons: [String] = f.item.reason.map { [$0] } ?? []
        if labelled.contains(f.cls) {
            if let id = f.label {
                if counts[id, default: 0] > 1 { reasons.append("duplicate id") }
            } else if let raw = f.raw {
                reasons.append("text \"\(raw)\" is not a readable id")
            } else {
                reasons.append("no label found")
            }
        } else {
            f.item.id = nil
            f.item.text = ""
        }
        f.item.needsReview = !reasons.isEmpty
        f.item.reason = reasons.isEmpty ? nil : reasons.joined(separator: "; ")
        items.append(f.item)
    }
    return items
}

// MARK: - Layer 2: everything outside the legend

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
        if seg.length >= minLength { out.append(seg) }
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

// Ink: low-saturation pixels clearly darker than the page background.
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

// Tile outlines are dark but often saturated (a dark red-brown), so the low-saturation ink rule misses them.
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

    // rawInk keeps pixels inside legend booths, used only to see whether a wall has a gap.
    // ink drops them, so booth outlines are not mistaken for walls or objects.
    let rawInk = inkMask(px)
    var ink = rawInk
    for i in 0..<n where claimed[i] { ink[i] = false }
    let scale = Double(mx) / 2000

    // Long straight strokes and solid blobs.
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

    // Text boxes, used to keep lettering out of pillars and objects.
    var textBoxes: [CGRect] = []
    let size = CGSize(width: w, height: h)
    if let found = try? await makeTextRequest().perform(on: image) {
        for o in found {
            textBoxes.append(o.boundingBox.toImageCoordinates(size, origin: .upperLeft).insetBy(dx: -3, dy: -3))
        }
    }
    var inText = [Bool](repeating: false, count: n)
    for box in textBoxes { fillRect(&inText, box, w: w, h: h, value: true) }

    // Walls: close pairs of lines or thick strokes are confident, other long strokes need review.
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

    // Doors: stretches of a wall band with no ink. Fall back to the outermost single lines.
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

    // Pillars: compact solid blobs that are not lettering.
    for reg in pillars {
        let center = CGPoint(x: Double(reg.minX + reg.maxX) / 2, y: Double(reg.minY + reg.maxY) / 2)
        if textBoxes.contains(where: { $0.contains(center) }) { continue }
        let rect = CGRect(x: reg.minX, y: reg.minY, width: reg.width, height: reg.height)
        items.append(outsideItem("pillar", rect, review: true, reason: "solid shape, confirm it is a pillar"))
    }

    // Objects: ink left after removing walls, pillars, legend cells and text, grouped by size and shape.
    var strokes = [Bool](repeating: false, count: n)
    for i in 0..<n { strokes[i] = hs[i] || vs[i] || thick[i] }
    let strokesNear = morph(strokes, w: w, h: h, rx: 3, ry: 3, erode: false)
    let pillarNear = morph(compact, w: w, h: h, rx: 4, ry: 4, erode: false)
    var rest = [Bool](repeating: false, count: n)
    for i in 0..<n { rest[i] = ink[i] && !strokesNear[i] && !pillarNear[i] && !inText[i] }
    let restNear = morph(rest, w: w, h: h, rx: 3, ry: 3, erode: false)

    struct Candidate { var rect: CGRect; var longSide: Double; var shortSide: Double; var fill: Double }
    var candidates: [Candidate] = []
    for reg in components(restNear, w: w, h: h, eight: true) {
        var x0 = w, y0 = h, x1 = 0, y1 = 0, count = 0
        for i in reg.pixels where rest[i] {
            let x = i % w, y = i / w
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y); count += 1
        }
        guard count > 0 else { continue }
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        guard max(bw, bh) >= max(6, Int(0.003 * Double(mx))), Double(bw * bh) <= 0.25 * Double(n) else { continue }
        candidates.append(Candidate(
            rect: CGRect(x: x0, y: y0, width: bw, height: bh),
            longSide: Double(max(bw, bh)), shortSide: Double(min(bw, bh)),
            fill: Double(count) / Double(bw * bh)))
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
            items.append(outsideItem(
                "object", candidates[i].rect, review: true,
                reason: members.count > 1
                    ? "label this group once (group \(g + 1), \(members.count) shapes)"
                    : "unique shape, label it"))
        }
    }
    return items
}

// MARK: - Merge

func extractLayout(plan: URL, legend: URL) async throws -> (image: CGImage, result: Result) {
    let planImage = try loadImage(plan)
    let legendImage = try loadImage(legend)
    let classes = try await readLegend(legendImage)
    guard !classes.isEmpty else { throw ExtractError.noLegend }
    let px = pixels(of: planImage)
    let (w, h) = (px.width, px.height)
    let scale = Double(max(w, h)) / 2000

    let legendItems = try await legendLayer(planImage, px, legend: classes)

    var claimed = [Bool](repeating: false, count: w * h)
    for item in legendItems {
        fillRect(&claimed, item.rect.insetBy(dx: -6 * scale, dy: -6 * scale), w: w, h: h, value: true)
    }

    var outside = await outsideLayer(planImage, px, claimed: claimed)
    outside.removeAll { item in
        guard item.cls == "object" || item.cls == "pillar" else { return false }
        let center = CGPoint(x: item.rect.midX, y: item.rect.midY)
        return legendItems.contains { $0.rect.contains(center) }
    }

    var items = legendItems + outside
    items.sort { ($0.box[1], $0.box[0]) < ($1.box[1], $1.box[0]) }
    let entries = classes.map {
        LegendEntry(label: $0.name, colors: [[Int($0.rgb.0), Int($0.rgb.1), Int($0.rgb.2)]], prefix: boothPrefix($0.name))
    }
    for warning in legendWarnings(classes) { FileHandle.standardError.write(Data("warning: \(warning)\n".utf8)) }
    let result = Result(image: ImageInfo(width: w, height: h), legend: entries, items: items, report: report(items))
    return (planImage, result)
}

@main
struct Tool {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            fputs("usage: extract_swift3 layout.png legend.png [--out dir]\n", stderr)
            exit(2)
        }
        let outDir = URL(fileURLWithPath: args.firstIndex(of: "--out").map { args[$0 + 1] } ?? "out_swift3")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let (image, result) = try await extractLayout(plan: URL(fileURLWithPath: args[1]), legend: URL(fileURLWithPath: args[2]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: outDir.appendingPathComponent("layout.json"))
        writeOverlay(image, items: result.items, to: outDir.appendingPathComponent("overlay.png"))
        print(String(decoding: try encoder.encode(result.report), as: UTF8.self))
    }
}
