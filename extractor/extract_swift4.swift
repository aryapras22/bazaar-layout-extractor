import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let gateDeltaE = 12.0
let marginDeltaE = 1.5
let legendWarnDeltaE = 10.0
let minSolidity = 0.85
let minColorCover = 0.4

enum ExtractError: Error { case unreadable(URL), noLegend }

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

func savePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
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

// Leave large enclosures and thin inter-tile seams open so hole filling closes only glyph interiors.
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

func solidity(_ reg: Region, w: Int) -> Double {
    let hullArea = polygonArea(convexHull(reg.pixels, w: w, minY: reg.minY, height: reg.height))
    return hullArea > 0 ? Double(reg.area) / hullArea : 0
}

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

func pointInPolygon(_ pt: CGPoint, _ poly: [[Int]]) -> Bool {
    guard poly.count >= 3 else { return false }
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let xi = Double(poly[i][0]), yi = Double(poly[i][1])
        let xj = Double(poly[j][0]), yj = Double(poly[j][1])
        let py = Double(pt.y), px = Double(pt.x)
        if ((yi > py) != (yj > py)), px < (xj - xi) * (py - yi) / (yj - yi) + xi {
            inside.toggle()
        }
        j = i
    }
    return inside
}

func boxIoU(_ a: [Int], _ b: [Int]) -> Double {
    let w = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    let h = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    guard w > 0, h > 0 else { return 0 }
    let inter = Double(w * h)
    return inter / (Double(a[2] * a[3] + b[2] * b[3]) - inter)
}

// Vision frequently returns Cyrillic homoglyphs for single-letter Latin booth labels and the digit 3.
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
    var s = Array(foldLookalikes(raw.uppercased()).filter { !$0.isWhitespace })
    while let first = s.first, !first.isLetter && !first.isNumber { s.removeFirst() }
    while let last = s.last, !last.isLetter && !last.isNumber { s.removeLast() }
    guard let firstDigit = s.firstIndex(where: { $0.isNumber }), (1...2).contains(firstDigit) else { return nil }
    let head = s[..<firstDigit]
    guard head.allSatisfy({ $0.isLetter }) else { return nil }
    let tail = s[firstDigit...].map { c -> Character in
        switch c {
        case "I", "L", "|": return "1"
        case "O": return "0"
        default: return c
        }
    }
    guard (1...3).contains(tail.count), tail.allSatisfy({ $0.isNumber }) else { return nil }
    return String(head) + String(tail)
}

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
    var source: String?
    var fillBox: [Int]?
    var suggestedId: String?
    var fixRule: String?
    var fixReason: String?

    enum CodingKeys: String, CodingKey {
        case cls = "class", box, area, fillRgb = "fill_rgb", legendRgb = "legend_rgb", text, id
        case needsReview = "needs_review", reason, polygon, source, fillBox = "fill_box"
        case suggestedId = "suggested_id", fixRule = "fix_rule", fixReason = "fix_reason"
    }

    var rect: CGRect { CGRect(x: box[0], y: box[1], width: box[2], height: box[3]) }
    var centerX: Double { Double(box[0]) + Double(box[2]) / 2 }
    var centerY: Double { Double(box[1]) + Double(box[3]) / 2 }
    var shortSide: Double { Double(min(box[2], box[3])) }
    var longSide: Double { Double(max(box[2], box[3])) }

    // Downstream renderers index item["id"] directly, so a missing ID must serialize as null.
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
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(fillBox, forKey: .fillBox)
        try c.encodeIfPresent(suggestedId, forKey: .suggestedId)
        try c.encodeIfPresent(fixRule, forKey: .fixRule)
        try c.encodeIfPresent(fixReason, forKey: .fixReason)
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

struct RereadStats: Codable {
    var blankTilesBefore: Int
    var cropsDumped: Int
    var maskedCropRecovered: Int
    var pageTextRecovered: Int
    var pageTextAdditionalRecovered: Int
    var totalRecovered: Int
    var applied: Bool

    enum CodingKeys: String, CodingKey {
        case blankTilesBefore = "blank_tiles_before"
        case cropsDumped = "crops_dumped"
        case maskedCropRecovered = "masked_crop_recovered"
        case pageTextRecovered = "page_text_recovered"
        case pageTextAdditionalRecovered = "page_text_additional_recovered"
        case totalRecovered = "total_recovered"
        case applied
    }
}

struct FeaturePrintStats: Codable {
    var enabled: Bool
    var intraGroupDistanceMedian: Double?
    var groupsBefore: Int
    var groupsAfter: Int
    var extraMerges: Int
    var mergedMoreThanModule: Bool

    enum CodingKeys: String, CodingKey {
        case enabled
        case intraGroupDistanceMedian = "intra_group_distance_median"
        case groupsBefore = "groups_before"
        case groupsAfter = "groups_after"
        case extraMerges = "extra_merges"
        case mergedMoreThanModule = "merged_more_than_module"
    }
}

struct SuggestedFix: Codable {
    var cls: String
    var box: [Int]
    var currentId: String?
    var text: String
    var suggestedId: String
    var rule: String
    var reason: String

    enum CodingKeys: String, CodingKey {
        case cls = "class"
        case box
        case currentId = "current_id"
        case text
        case suggestedId = "suggested_id"
        case rule
        case reason
    }
}

struct DiffReport: Codable {
    var swift3ItemsPerClass: [String: Int]
    var swift4ItemsPerClass: [String: Int]
    var swift3IdsRead: Int
    var swift4IdsRead: Int
    var flaggedBefore: Int
    var flaggedAfter: Int
    var blankTiles: RereadStats
    var idsSuggested: [SuggestedFix]
    var ruleCounts: [String: Int]
    var featurePrint: FeaturePrintStats
    var judge: JudgeReport

    enum CodingKeys: String, CodingKey {
        case swift3ItemsPerClass = "swift3_items_per_class"
        case swift4ItemsPerClass = "swift4_items_per_class"
        case swift3IdsRead = "swift3_ids_read"
        case swift4IdsRead = "swift4_ids_read"
        case flaggedBefore = "flagged_before"
        case flaggedAfter = "flagged_after"
        case blankTiles = "blank_tiles_recovered"
        case idsSuggested = "ids_suggested"
        case ruleCounts = "rule_counts"
        case featurePrint = "feature_print"
        case judge
    }
}

func parseStrictId(_ id: String?) -> (prefix: String, number: Int)? {
    guard let id, !id.isEmpty,
          let split = id.firstIndex(where: \.isNumber),
          split > id.startIndex
    else { return nil }
    let head = id[..<split]
    let tail = id[split...]
    guard head.allSatisfy(\.isLetter), tail.allSatisfy(\.isNumber), let n = Int(tail), n >= 1 else { return nil }
    return (String(head), n)
}

func report(_ items: [Item]) -> Report {
    let ids = items.compactMap(\.id)
    var nums: [String: Set<Int>] = [:]
    for id in ids {
        guard let parsed = parseStrictId(id) else { continue }
        nums[parsed.prefix, default: []].insert(parsed.number)
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
        let color: CGColor
        if item.id != nil {
            color = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        } else if item.suggestedId != nil {
            color = CGColor(red: 0, green: 0.7, blue: 0.2, alpha: 1)
        } else {
            color = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        }
        ctx.setStrokeColor(color)
        ctx.stroke(CGRect(x: item.box[0], y: h - item.box[1] - item.box[3], width: item.box[2], height: item.box[3]))
    }
    savePNG(ctx.makeImage()!, to: url)
}

func box(_ r: CGRect) -> [Int] {
    [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)]
}

func outsideItem(_ kind: String, _ rect: CGRect, review: Bool, reason: String?) -> Item {
    Item(cls: kind, box: box(rect), area: Int(rect.width * rect.height), fillRgb: [128, 128, 128],
         legendRgb: [128, 128, 128], text: "", id: nil, needsReview: review, reason: reason)
}

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

// A legend swatch is a block of one colour that is bigger than a line and smaller than the page.
// Flood fill from a seed: a thin rule stays tiny, the page background runs into the image border.
func isSwatch(_ px: Pixels, seedX: Int, seedY: Int, textHeight: Int) -> Bool {
    let (w, h) = (px.width, px.height)
    let seed = lab(px.rgb(seedX, seedY))
    let maxArea = 100 * textHeight * textHeight
    var seen = Set<Int>([seedY * w + seedX])
    var stack = [seedY * w + seedX]
    var x0 = seedX, x1 = seedX, y0 = seedY, y1 = seedY
    while let i = stack.popLast() {
        let x = i % w, y = i / w
        if x == 0 || y == 0 || x == w - 1 || y == h - 1 || seen.count > maxArea { return false }
        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        for j in [i - 1, i + 1, i - w, i + w] where !seen.contains(j) {
            if distance(lab(px.rgb(j % w, j / w)), seed) < 6 { seen.insert(j); stack.append(j) }
        }
    }
    return min(x1 - x0, y1 - y0) + 1 >= textHeight / 2
}

func readLegend(_ image: CGImage) async throws -> [LegendClass] {
    let px = pixels(of: image)
    let size = CGSize(width: image.width, height: image.height)
    var classes: [LegendClass] = []
    var boxes: [CGRect] = []
    var wrapped: [(text: String, box: CGRect)] = []
    // The legend may sit on a tinted ground, so the most common colour counts as blank, not only white.
    var counts: [UInt32: Int] = [:]
    for i in stride(from: 0, to: px.width * px.height, by: 7) {
        counts[UInt32(px.rgba[i * 4] >> 3) << 16 | UInt32(px.rgba[i * 4 + 1] >> 3) << 8 | UInt32(px.rgba[i * 4 + 2] >> 3), default: 0] += 1
    }
    let ground = counts.max { $0.value < $1.value }?.key ?? 0x1F1F1F
    let groundLab = lab((UInt8(ground >> 16) << 3 | 4, UInt8((ground >> 8) & 31) << 3 | 4, UInt8(ground & 31) << 3 | 4))
    for observation in try await makeTextRequest().perform(on: image) {
        let name = foldLookalikes(observation.transcript)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
        guard !name.isEmpty,
              !classes.contains(where: { $0.name.lowercased() == name.lowercased() })
        else { continue }
        let box = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
        let y = Int(box.midY)
        guard y >= 0, y < px.height else { continue }
        var x = Int(box.minX) - 1
        while x > 8, isNearWhite(px.rgb(x, y)) || distance(lab(px.rgb(x, y)), groundLab) < 8 { x -= 1 }
        guard x > 8 else { continue }
        let color = px.rgb(x - 8, y)
        if isSwatch(px, seedX: x - 8, seedY: y, textHeight: max(1, Int(box.height))) {
            classes.append(LegendClass(name: name, rgb: color, lab: lab(color)))
            boxes.append(box)
        } else {
            wrapped.append((name, box))
        }
    }
    // A line with no swatch that sits just under an entry is that entry's second line. Anything else is a title.
    for line in wrapped.sorted(by: { $0.box.minY < $1.box.minY }) {
        let h = line.box.height
        guard let owner = boxes.indices.filter({
            let gap = line.box.minY - boxes[$0].maxY
            return gap > -h / 2 && gap < 1.2 * h
                && line.box.minX > boxes[$0].minX - h && line.box.minX < boxes[$0].minX + 3 * h
        }).max(by: { boxes[$0].maxY < boxes[$1].maxY }) else { continue }
        classes[owner] = LegendClass(name: classes[owner].name + " " + line.text, rgb: classes[owner].rgb, lab: classes[owner].lab)
        boxes[owner] = boxes[owner].union(line.box)
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

struct LegendLayerOutput {
    var items: [Item]
    var labelledClasses: Set<String>
    var colorReasons: [[String]]
}

func rebuildLabelledReasons(_ items: inout [Item], labelledClasses: Set<String>, colorReasons: [[String]]) {
    var counts: [String: Int] = [:]
    for item in items where labelledClasses.contains(item.cls) {
        if let id = item.id { counts[id, default: 0] += 1 }
    }
    for i in items.indices {
        var reasons = i < colorReasons.count ? colorReasons[i] : []
        if labelledClasses.contains(items[i].cls) {
            if let id = items[i].id {
                if counts[id, default: 0] > 1 { reasons.append("duplicate id") }
            } else if !items[i].text.isEmpty {
                reasons.append("text \"\(items[i].text)\" is not a readable id")
            } else {
                reasons.append("no label found")
            }
        }
        items[i].needsReview = !reasons.isEmpty
        items[i].reason = reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }
}

func legendLayer(_ image: CGImage, _ px: Pixels, legend: [LegendClass]) async throws -> LegendLayerOutput {
    let (w, h) = (px.width, px.height)
    let scale = Double(max(w, h)) / 2000
    let r = max(1, Int((3 * scale).rounded()))
    let minArea = Int(400 * scale * scale)
    let maxHole = Int(2000 * scale * scale)
    let seamLength = Int(20 * scale)
    let canvas = CGRect(x: 0, y: 0, width: w, height: h)
    let grid = classify(px, legend: legend)
    let outlines = morph(darkPixels(px, below: 60), w: w, h: h, rx: 1, ry: 1, erode: false)
    let faces = components(outlines.map { !$0 }, w: w, h: h, eight: false)
    var faceOf = [Int32](repeating: -1, count: w * h)
    for (j, face) in faces.enumerated() { for i in face.pixels { faceOf[i] = Int32(j) } }

    struct Found {
        var item: Item
        let cls: Int
        let colorReasons: [String]
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

            var tileArea = 0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) where grid[y * w + x] == Int16(k) { tileArea += 1 }
            }
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
                cls: k, colorReasons: reasons))
        }
    }

    var labelledIndices = Set<Int>()
    for k in legend.indices {
        let members = found.filter { $0.cls == k }
        let withLabel = members.filter { $0.item.id != nil }.count
        if !members.isEmpty, withLabel * 2 >= members.count { labelledIndices.insert(k) }
    }
    let labelledNames = Set(labelledIndices.map { legend[$0].name })
    var items: [Item] = []
    var colorReasons: [[String]] = []
    for var f in found {
        if !labelledIndices.contains(f.cls) {
            f.item.id = nil
            f.item.text = ""
        }
        items.append(f.item)
        colorReasons.append(f.colorReasons)
    }
    rebuildLabelledReasons(&items, labelledClasses: labelledNames, colorReasons: colorReasons)
    return LegendLayerOutput(items: items, labelledClasses: labelledNames, colorReasons: colorReasons)
}

func makeMaskedUpscaledCrop(_ image: CGImage, item: Item, scale: Int) -> CGImage? {
    let bx = item.box[0], by = item.box[1], bw = item.box[2], bh = item.box[3]
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let srcRect = CGRect(x: bx, y: by, width: bw, height: bh).intersection(bounds)
    guard srcRect.width >= 2, srcRect.height >= 2, let sub = image.cropping(to: srcRect) else { return nil }
    let pad = max(2, Int((0.2 * Double(min(bw, bh))).rounded()))
    let cw = (Int(srcRect.width) + 2 * pad) * scale
    let ch = (Int(srcRect.height) + 2 * pad) * scale
    guard let ctx = CGContext(
        data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
    ctx.saveGState()
    if let poly = item.polygon, poly.count >= 3 {
        let path = CGMutablePath()
        for (idx, pt) in poly.enumerated() {
            let px = CGFloat(Double(pt[0]) - Double(srcRect.minX) + Double(pad)) * CGFloat(scale)
            let py = CGFloat(Double(srcRect.height) - (Double(pt[1]) - Double(srcRect.minY)) + Double(pad)) * CGFloat(scale)
            if idx == 0 { path.move(to: CGPoint(x: px, y: py)) }
            else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.clip()
    }
    ctx.interpolationQuality = .high
    ctx.draw(sub, in: CGRect(
        x: pad * scale, y: pad * scale,
        width: Int(srcRect.width) * scale, height: Int(srcRect.height) * scale
    ))
    ctx.restoreGState()
    return ctx.makeImage()
}

// Booths drawn as light boxes on a coloured zone have no legend colour of their own, so they are
// found as closed light regions of booth size and kept only when an ID reads inside.
func outlinedLayer(_ image: CGImage, _ px: Pixels, existing: [Item]) async -> [Item] {
    let (w, h) = (px.width, px.height)
    let mx = max(w, h)
    let scale = Double(mx) / 2000
    let outlines = morph(darkPixels(px, below: 60), w: w, h: h, rx: 1, ry: 1, erode: false)
    let minSide = Int(0.008 * Double(mx)), maxSide = Int(0.07 * Double(mx))
    var items: [Item] = []
    for face in components(outlines.map { !$0 }, w: w, h: h, eight: false) {
        guard min(face.width, face.height) >= minSide, max(face.width, face.height) <= maxSide,
              face.minX > 0, face.minY > 0, face.maxX < w - 1, face.maxY < h - 1,
              face.fill >= 0.6, face.fill < 0.98
        else { continue }
        let light = face.pixels.filter { i in
            let c = px.rgb(i % w, i / w)
            return min(c.0, min(c.1, c.2)) >= 235
        }.count
        guard Double(light) >= 0.7 * Double(face.area) else { continue }
        let rect = CGRect(x: face.minX, y: face.minY, width: face.width, height: face.height)
            .insetBy(dx: -2 * scale, dy: -2 * scale)
        guard !existing.contains(where: { boxIoU($0.box, box(rect)) >= 0.3 }) else { continue }
        var tile = outsideItem("Booth", rect, review: false, reason: nil)
        guard let crop = makeMaskedUpscaledCrop(image, item: tile, scale: 3),
              let found = try? await makeTextRequest().perform(on: crop),
              let read = found.sorted(by: { $0.confidence > $1.confidence })
                  .compactMap({ obs in cleanLabel(obs.transcript).map { (obs.transcript, $0) } }).first
        else { continue }
        tile.cls = "Booth " + String(read.1.prefix { $0.isLetter })
        tile.fillRgb = [255, 255, 255]
        tile.legendRgb = [255, 255, 255]
        tile.text = read.0
        tile.id = read.1
        tile.source = "outlined"
        items.append(tile)
    }
    return items
}

func rereadTiles(
    _ image: CGImage,
    items: inout [Item],
    labelledClasses: Set<String>,
    colorReasons: [[String]],
    outDir: URL,
    apply: Bool,
    ruleCounts: inout [String: Int]
) async throws -> RereadStats {
    let idShorts = items.filter { $0.id != nil }.map(\.shortSide).sorted()
    let medianIdShort = idShorts.isEmpty ? 0 : idShorts[idShorts.count / 2]
    let blankIndices = items.indices.filter { i in
        guard items[i].id == nil else { return false }
        if labelledClasses.contains(items[i].cls) { return true }
        return medianIdShort > 0 && (0.5...2.5).contains(items[i].shortSide / medianIdShort)
    }
    let cropsDir = outDir.appendingPathComponent("crops")
    try FileManager.default.createDirectory(at: cropsDir, withIntermediateDirectories: true)
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    var dumped = 0
    for idx in blankIndices {
        let b = items[idx].box
        if let rawCrop = image.cropping(to: CGRect(x: b[0], y: b[1], width: b[2], height: b[3]).intersection(bounds)) {
            let safeCls = items[idx].cls.replacingOccurrences(of: " ", with: "_")
            let name = "tile_\(idx)_\(safeCls)_\(b[0])_\(b[1]).png"
            savePNG(rawCrop, to: cropsDir.appendingPathComponent(name))
            dumped += 1
        }
    }

    guard !blankIndices.isEmpty else {
        return RereadStats(
            blankTilesBefore: 0, cropsDumped: dumped, maskedCropRecovered: 0,
            pageTextRecovered: 0, pageTextAdditionalRecovered: 0, totalRecovered: 0, applied: apply
        )
    }

    var maskedHits: [Int: (raw: String, cleaned: String?)] = [:]
    for idx in blankIndices {
        var bestRaw: String?
        var bestClean: String?
        var bestScore = -1.0
        for scale in [2, 3] {
            guard let up = makeMaskedUpscaledCrop(image, item: items[idx], scale: scale) else { continue }
            for obs in try await makeTextRequest().perform(on: up) {
                let raw = obs.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                let cleaned = cleanLabel(raw)
                let score = (cleaned != nil ? 10.0 : 0.0) + Double(obs.confidence)
                if score > bestScore {
                    bestScore = score
                    bestRaw = raw
                    bestClean = cleaned
                }
            }
        }
        if let raw = bestRaw {
            maskedHits[idx] = (raw, bestClean)
        }
    }

    let labelledShorts = items.filter { labelledClasses.contains($0.cls) }.map(\.shortSide).sorted()
    let medianShort = labelledShorts.isEmpty ? 40.0 : labelledShorts[labelledShorts.count / 2]
    var pageReq = makeTextRequest()
    pageReq.minimumTextHeightFraction = Float(max(0.001, 0.15 * medianShort / Double(image.height)))
    let pageObs = try await pageReq.perform(on: image)
    let pageSize = CGSize(width: image.width, height: image.height)

    // Assign each page-level text box to the single labelled tile that owns its center pixel.
    var pageHits: [Int: (raw: String, cleaned: String?, score: Double)] = [:]
    let labelledItemIndices = items.indices.filter { labelledClasses.contains(items[$0].cls) }
    for obs in pageObs {
        let raw = obs.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { continue }
        let b = obs.boundingBox.toImageCoordinates(pageSize, origin: .upperLeft)
        let center = CGPoint(x: b.midX, y: b.midY)
        var owner: Int?
        var ownerArea = Int.max
        for ti in labelledItemIndices where items[ti].rect.contains(center) {
            if let poly = items[ti].polygon, poly.count >= 3, !pointInPolygon(center, poly) {
                continue
            }
            if items[ti].area < ownerArea {
                ownerArea = items[ti].area
                owner = ti
            }
        }
        guard let ti = owner else { continue }
        let cleaned = cleanLabel(raw)
        let score = (cleaned != nil ? 10.0 : 0.0) + Double(obs.confidence)
        if score > (pageHits[ti]?.score ?? -1.0) {
            pageHits[ti] = (raw, cleaned, score)
        }
    }

    var maskedRecoveredCount = 0
    var pageRecoveredCount = 0
    var pageAdditionalCount = 0
    var totalRecoveredCount = 0

    for idx in blankIndices {
        let mHit = maskedHits[idx]
        let pHit = pageHits[idx]
        let mValid = mHit?.cleaned != nil
        let pValid = pHit?.cleaned != nil
        if mValid { maskedRecoveredCount += 1 }
        if pValid { pageRecoveredCount += 1 }
        if !mValid && pValid { pageAdditionalCount += 1 }

        let chosen: (raw: String, cleaned: String?)?
        if mValid {
            chosen = mHit
        } else if let p = pHit, pValid {
            chosen = (p.raw, p.cleaned)
        } else if let m = mHit {
            chosen = m
        } else if let p = pHit {
            chosen = (p.raw, p.cleaned)
        } else {
            chosen = nil
        }

        if let chosen, chosen.cleaned != nil {
            totalRecoveredCount += 1
        }
        if apply, let chosen {
            items[idx].text = chosen.raw
            items[idx].id = chosen.cleaned
            if chosen.cleaned != nil {
                ruleCounts["reread-tile", default: 0] += 1
            }
        }
    }

    if apply {
        rebuildLabelledReasons(&items, labelledClasses: labelledClasses, colorReasons: colorReasons)
    }

    return RereadStats(
        blankTilesBefore: blankIndices.count,
        cropsDumped: dumped,
        maskedCropRecovered: maskedRecoveredCount,
        pageTextRecovered: pageRecoveredCount,
        pageTextAdditionalRecovered: pageAdditionalCount,
        totalRecovered: totalRecoveredCount,
        applied: apply
    )
}

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

func makeOrientedObjectCrop(_ image: CGImage, box: [Int]) -> CGImage? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3]).intersection(bounds).integral
    guard rect.width >= 2, rect.height >= 2, let sub = image.cropping(to: rect) else { return nil }
    let w = sub.width, h = sub.height
    let outW = max(w, h), outH = min(w, h)
    let scale = max(1, Int((64.0 / Double(max(1, outH))).rounded(.up)))
    let cw = outW * scale, ch = outH * scale
    guard let ctx = CGContext(
        data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
    ctx.interpolationQuality = .high
    if h > w {
        ctx.translateBy(x: CGFloat(cw), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: ch, height: cw))
    } else {
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: cw, height: ch))
    }
    return ctx.makeImage()
}

func regroupObjects(
    _ image: CGImage,
    items: inout [Item],
    enableModule: Bool,
    enableFeaturePrint: Bool,
    ruleCounts: inout [String: Int]
) async -> FeaturePrintStats {
    let objIndices = items.indices.filter { items[$0].cls == "object" && items[$0].id == nil }
    guard !objIndices.isEmpty else {
        return FeaturePrintStats(
            enabled: enableFeaturePrint, intraGroupDistanceMedian: nil,
            groupsBefore: 0, groupsAfter: 0, extraMerges: 0, mergedMoreThanModule: false
        )
    }

    var keyedGroups: [String: [Int]] = [:]
    var orderedKeys: [String] = []
    for idx in objIndices {
        let reason = items[idx].reason ?? ""
        let key: String
        if reason.hasPrefix("label this group once (") {
            key = reason
        } else {
            key = "singleton-\(idx)"
        }
        if keyedGroups[key] == nil { orderedKeys.append(key) }
        keyedGroups[key, default: []].append(idx)
    }
    var groups: [[Int]] = orderedKeys.compactMap { keyedGroups[$0] }

    func groupShort(_ members: [Int]) -> Double {
        let s = members.map { items[$0].shortSide }.sorted()
        return s[s.count / 2]
    }
    func groupLong(_ members: [Int]) -> Double {
        let l = members.map { items[$0].longSide }.sorted()
        return l[l.count / 2]
    }
    func moduleFactor(_ members: [Int]) -> Int? {
        let s = groupShort(members), l = groupLong(members)
        guard s > 0 else { return nil }
        let k = Int((l / s).rounded())
        guard (1...3).contains(k), abs(l - Double(k) * s) <= 0.1 * Double(k) * s else { return nil }
        return k
    }

    var mergedByModuleIndices = Set<Int>()
    if enableModule {
        var parent = Array(groups.indices)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            return r
        }
        for a in groups.indices {
            guard moduleFactor(groups[a]) != nil else { continue }
            let sA = groupShort(groups[a])
            for b in (a + 1)..<groups.count {
                guard moduleFactor(groups[b]) != nil else { continue }
                let sB = groupShort(groups[b])
                if abs(sA - sB) <= 0.1 * max(sA, sB) {
                    let ra = find(a), rb = find(b)
                    if ra != rb { parent[rb] = ra }
                }
            }
        }
        var bucketed: [Int: [[Int]]] = [:]
        var bucketOrder: [Int] = []
        for g in groups.indices {
            let r = find(g)
            if bucketed[r] == nil { bucketOrder.append(r) }
            bucketed[r, default: []].append(groups[g])
        }
        var nextGroups: [[Int]] = []
        for r in bucketOrder {
            let parts = bucketed[r]!
            let combined = parts.flatMap { $0 }
            nextGroups.append(combined)
            if parts.count > 1 {
                ruleCounts["module-merge", default: 0] += 1
                let s = Int(groupShort(combined).rounded())
                for idx in combined {
                    mergedByModuleIndices.insert(idx)
                    items[idx].fixRule = "module-merge"
                    items[idx].fixReason = "merged \(parts.count) modular object groups (1x..3x of short side \(s))"
                }
            }
        }
        groups = nextGroups
    }

    let groupsBeforeFP = groups.count
    var fpStats = FeaturePrintStats(
        enabled: enableFeaturePrint, intraGroupDistanceMedian: nil,
        groupsBefore: groupsBeforeFP, groupsAfter: groupsBeforeFP,
        extraMerges: 0, mergedMoreThanModule: false
    )

    if enableFeaturePrint, groups.count >= 2 {
        var intraDistances: [Double] = []
        var repPrints: [Int: FeaturePrintObservation] = [:]

        for g in groups.indices {
            let sampleMembers = Array(groups[g].prefix(3))
            var prints: [FeaturePrintObservation] = []
            for idx in sampleMembers {
                if let crop = makeOrientedObjectCrop(image, box: items[idx].box),
                   let obs = try? await GenerateImageFeaturePrintRequest().perform(on: crop)
                {
                    prints.append(obs)
                }
            }
            if let first = prints.first { repPrints[g] = first }
            if prints.count >= 2 {
                for i in 0..<prints.count {
                    for j in (i + 1)..<prints.count {
                        if let d = try? prints[i].distance(to: prints[j]) {
                            intraDistances.append(d)
                        }
                    }
                }
            }
        }

        if !intraDistances.isEmpty {
            let sortedIntra = intraDistances.sorted()
            let med = sortedIntra[sortedIntra.count / 2]
            fpStats.intraGroupDistanceMedian = med

            var parent = Array(groups.indices)
            func find(_ x: Int) -> Int {
                var r = x
                while parent[r] != r { r = parent[r] }
                return r
            }
            for a in groups.indices {
                guard let pA = repPrints[a] else { continue }
                let sA = groupShort(groups[a])
                for b in (a + 1)..<groups.count {
                    guard let pB = repPrints[b] else { continue }
                    let sB = groupShort(groups[b])
                    guard abs(sA - sB) <= 0.15 * max(sA, sB),
                          let d = try? pA.distance(to: pB),
                          d <= med
                    else { continue }
                    let ra = find(a), rb = find(b)
                    if ra != rb { parent[rb] = ra }
                }
            }
            var bucketed: [Int: [[Int]]] = [:]
            var bucketOrder: [Int] = []
            for g in groups.indices {
                let r = find(g)
                if bucketed[r] == nil { bucketOrder.append(r) }
                bucketed[r, default: []].append(groups[g])
            }
            var nextGroups: [[Int]] = []
            var extraMerges = 0
            for r in bucketOrder {
                let parts = bucketed[r]!
                let combined = parts.flatMap { $0 }
                nextGroups.append(combined)
                if parts.count > 1 {
                    extraMerges += parts.count - 1
                    ruleCounts["feature-print-merge", default: 0] += 1
                    for idx in combined where items[idx].fixRule == nil {
                        items[idx].fixRule = "feature-print-merge"
                        items[idx].fixReason = "feature-print distance within intra-group median (\(String(format: "%.3f", med)))"
                    }
                }
            }
            groups = nextGroups
            fpStats.groupsAfter = groups.count
            fpStats.extraMerges = extraMerges
            fpStats.mergedMoreThanModule = extraMerges > 0
        }
    }

    if enableModule || fpStats.extraMerges > 0 {
        var multiGroupNumber = 0
        for members in groups {
            if members.count > 1 {
                multiGroupNumber += 1
                let label = "label this group once (group \(multiGroupNumber), \(members.count) shapes)"
                for idx in members { items[idx].reason = label }
            } else {
                items[members[0]].reason = "unique shape, label it"
            }
        }
    }

    return fpStats
}

func expandOCRDigits(_ chars: [Character]) -> [String] {
    var acc = [""]
    for c in chars {
        let choices: [String]
        switch c {
        case "I", "L", "|", "E": choices = ["1"]
        case "O": choices = ["0"]
        case "Z": choices = ["7", "2"]
        default:
            guard c.isNumber else { return [] }
            choices = [String(c)]
        }
        var next: [String] = []
        for prefix in acc {
            for ch in choices { next.append(prefix + ch) }
        }
        acc = next
    }
    return acc
}

func prefixMatchesLeadingDigit(prefix: String, digit: Character) -> Bool {
    guard prefix.count == 1, let p = prefix.first else { return false }
    switch p {
    case "I", "L": return digit == "1"
    case "O": return digit == "0"
    case "Z": return digit == "7" || digit == "2"
    default: return false
    }
}

func checkMonotoneNumbers(_ values: [Int]) -> Int? {
    guard values.count >= 2 else { return nil }
    let inc = zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
    if inc { return 1 }
    let dec = zip(values, values.dropFirst()).allSatisfy { $0 > $1 }
    if dec { return -1 }
    return nil
}

func assignMonotoneSequence(
    known: [(idx: Int, num: Int)],
    candidates: [Int],
    gaps: [Int],
    items: [Item]
) -> [(idx: Int, gap: Int, axisDesc: String)]? {
    guard known.count >= 2, candidates.count == gaps.count, !gaps.isEmpty else { return nil }
    let allKnownNums = Set(known.map(\.num))

    func trySubset(
        subsetKnown: [(idx: Int, num: Int)],
        horizontalAxis: Bool,
        scopeLabel: String,
        enforceContiguousRange: Bool
    ) -> [(idx: Int, gap: Int, axisDesc: String)]? {
        guard subsetKnown.count >= 2 else { return nil }
        func coord(_ idx: Int) -> Double { horizontalAxis ? items[idx].centerX : items[idx].centerY }
        let orderedKnown = subsetKnown.sorted { coord($0.idx) < coord($1.idx) }
        for k in 1..<orderedKnown.count where abs(coord(orderedKnown[k].idx) - coord(orderedKnown[k - 1].idx)) < 1e-6 {
            return nil
        }
        guard let dir = checkMonotoneNumbers(orderedKnown.map(\.num)) else { return nil }

        struct Entry { let idx: Int; let knownNum: Int? }
        var combined: [Entry] = orderedKnown.map { Entry(idx: $0.idx, knownNum: $0.num) }
            + candidates.map { Entry(idx: $0, knownNum: nil) }
        combined.sort { coord($0.idx) < coord($1.idx) }

        let orderedGaps = dir > 0 ? gaps.sorted() : gaps.sorted(by: >)
        var gapPos = 0
        var fullNumbers: [Int] = []
        var assignments: [(idx: Int, gap: Int, axisDesc: String)] = []
        let axisName = horizontalAxis ? "x" : "y"

        for entry in combined {
            if let n = entry.knownNum {
                fullNumbers.append(n)
            } else {
                let g = orderedGaps[gapPos]
                gapPos += 1
                fullNumbers.append(g)
                assignments.append((entry.idx, g, "\(scopeLabel) monotone \(axisName)-axis"))
            }
        }
        guard checkMonotoneNumbers(fullNumbers) == dir else { return nil }
        if enforceContiguousRange, let lo = fullNumbers.min(), let hi = fullNumbers.max() {
            let subsetSet = Set(fullNumbers)
            let outsideNums = allKnownNums.subtracting(subsetSet)
            if outsideNums.contains(where: { (lo...hi).contains($0) }) {
                return nil
            }
        }
        return assignments
    }

    let allIndices = known.map(\.idx) + candidates
    let xs = allIndices.map { items[$0].centerX }
    let ys = allIndices.map { items[$0].centerY }
    let spreadX = (xs.max() ?? 0) - (xs.min() ?? 0)
    let spreadY = (ys.max() ?? 0) - (ys.min() ?? 0)
    let primaryHorizontal = spreadX >= spreadY

    if let hit = trySubset(subsetKnown: known, horizontalAxis: primaryHorizontal, scopeLabel: "class", enforceContiguousRange: false) {
        return hit
    }
    if let hit = trySubset(subsetKnown: known, horizontalAxis: !primaryHorizontal, scopeLabel: "class", enforceContiguousRange: false) {
        return hit
    }

    // Wrapped perimeter classes remain monotone along individual collinear rows or columns.
    let longs = allIndices.map { items[$0].longSide }.sorted()
    let bandTol = longs[longs.count / 2]
    let candXs = candidates.map { items[$0].centerX }
    let candYs = candidates.map { items[$0].centerY }
    let candSpreadX = (candXs.max() ?? 0) - (candXs.min() ?? 0)
    let candSpreadY = (candYs.max() ?? 0) - (candYs.min() ?? 0)

    if candSpreadX <= bandTol {
        let meanX = candXs.reduce(0, +) / Double(candXs.count)
        let bandKnown = known.filter { abs(items[$0.idx].centerX - meanX) <= bandTol }
        if let hit = trySubset(subsetKnown: bandKnown, horizontalAxis: false, scopeLabel: "column", enforceContiguousRange: true) {
            return hit
        }
    }
    if candSpreadY <= bandTol {
        let meanY = candYs.reduce(0, +) / Double(candYs.count)
        let bandKnown = known.filter { abs(items[$0.idx].centerY - meanY) <= bandTol }
        if let hit = trySubset(subsetKnown: bandKnown, horizontalAxis: true, scopeLabel: "row", enforceContiguousRange: true) {
            return hit
        }
    }
    return nil
}

func computeClassPrefixes(_ items: [Item]) -> [String: String] {
    let byClass = Dictionary(grouping: items.indices, by: { items[$0].cls })
    var out: [String: String] = [:]
    for (cls, indices) in byClass {
        var prefixCounts: [String: Int] = [:]
        var totalParsed = 0
        for idx in indices {
            if let parsed = parseStrictId(items[idx].id) {
                prefixCounts[parsed.prefix, default: 0] += 1
                totalParsed += 1
            }
        }
        guard totalParsed > 0, totalParsed * 2 >= indices.count,
              let majority = prefixCounts.max(by: { $0.value < $1.value })?.key
        else { continue }
        out[cls] = majority
    }
    return out
}

func computeUnresolvedGapIds(items: [Item], classPrefixes: [String: String]) -> [String: [String]] {
    var result: [String: [String]] = [:]
    let byClass = Dictionary(grouping: items.indices, by: { items[$0].cls })
    for (cls, prefix) in classPrefixes {
        guard let indices = byClass[cls] else { continue }
        var present = Set<Int>()
        var extraCount = 0
        for idx in indices {
            if let parsed = parseStrictId(items[idx].id), parsed.prefix == prefix {
                present.insert(parsed.number)
            } else {
                let raw = foldLookalikes((items[idx].id ?? items[idx].text).uppercased()).filter { !$0.isWhitespace }
                if let first = raw.first, prefixMatchesLeadingDigit(prefix: prefix, digit: first),
                   let n = Int(raw.dropFirst()), n >= 1, !present.contains(n)
                {
                    extraCount = max(extraCount, n)
                }
            }
        }
        let maxNum = max(present.max() ?? 0, extraCount)
        guard maxNum >= 1 else { continue }
        let missing = Set(1...maxNum).subtracting(present).sorted()
        if !missing.isEmpty {
            result[cls] = missing.map { "\(prefix)\($0)" }
        }
    }
    return result
}

func repairIds(_ items: inout [Item], classPrefixes: [String: String], ruleCounts: inout [String: Int]) {
    var classesByExactId: [String: Set<String>] = [:]
    for item in items {
        if let id = item.id {
            classesByExactId[id, default: []].insert(item.cls)
        }
    }

    let byClass = Dictionary(grouping: items.indices, by: { items[$0].cls })
    for cls in classPrefixes.keys.sorted() {
        guard let prefix = classPrefixes[cls], let indices = byClass[cls] else { continue }

        for idx in indices where !items[idx].needsReview {
            if let parsed = parseStrictId(items[idx].id), parsed.prefix == prefix {
                continue
            }
            items[idx].needsReview = true
            let shown = items[idx].id ?? items[idx].text
            let msg = "id \"\(shown)\" does not match class pattern \"\(prefix)<n>\""
            items[idx].reason = items[idx].reason.map { "\($0); \(msg)" } ?? msg
            if items[idx].fixRule == nil {
                items[idx].fixRule = "id-pattern"
                items[idx].fixReason = msg
            }
            ruleCounts["id-pattern", default: 0] += 1
        }

        var known: [(idx: Int, num: Int)] = []
        var effectivePresent = Set<Int>()
        var unresolved: [Int] = []

        for idx in indices {
            if let parsed = parseStrictId(items[idx].id), parsed.prefix == prefix {
                known.append((idx, parsed.number))
                effectivePresent.insert(parsed.number)
            } else {
                unresolved.append(idx)
            }
        }
        guard !effectivePresent.isEmpty else { continue }

        // Resolve prefix-digit OCR confusions such as "19" -> I9 before counting remaining gaps.
        var stillUnresolved: [Int] = []
        for idx in unresolved {
            let raw = Array(foldLookalikes((items[idx].id ?? items[idx].text).uppercased()).filter { !$0.isWhitespace })
            let curMax = effectivePresent.max() ?? 0
            if raw.count >= 2, prefixMatchesLeadingDigit(prefix: prefix, digit: raw[0]),
               raw.dropFirst().allSatisfy(\.isNumber),
               let n = Int(String(raw.dropFirst())),
               (1...(curMax + 1)).contains(n), !effectivePresent.contains(n)
            {
                items[idx].suggestedId = "\(prefix)\(n)"
                items[idx].fixRule = "ocr-confusion"
                items[idx].fixReason = "\"\(String(raw))\" has leading digit \"\(raw[0])\" confused with prefix \"\(prefix)\""
                effectivePresent.insert(n)
                ruleCounts["ocr-confusion", default: 0] += 1
            } else {
                stillUnresolved.append(idx)
            }
        }
        unresolved = stillUnresolved

        guard let maxNum = effectivePresent.max(), maxNum >= 1 else { continue }
        var remainingGaps = Set(1...maxNum).subtracting(effectivePresent).sorted()

        stillUnresolved = []
        for idx in unresolved {
            if let id = items[idx].id, let parsed = parseStrictId(id), parsed.prefix != prefix,
               remainingGaps.contains(parsed.number),
               let holders = classesByExactId[id], holders.contains(where: { $0 != cls })
            {
                items[idx].suggestedId = "\(prefix)\(parsed.number)"
                items[idx].fixRule = "prefix-conflict"
                items[idx].fixReason = "\"\(id)\" already exists in another class and \(prefix)\(parsed.number) is a gap here"
                remainingGaps.removeAll { $0 == parsed.number }
                effectivePresent.insert(parsed.number)
                ruleCounts["prefix-conflict", default: 0] += 1
            } else {
                stillUnresolved.append(idx)
            }
        }
        unresolved = stillUnresolved

        guard !remainingGaps.isEmpty, unresolved.count == remainingGaps.count else { continue }

        var gapSet = Set(remainingGaps)
        var ocrMatched: [(idx: Int, gap: Int, raw: String)] = []
        for idx in unresolved {
            let token = Array(foldLookalikes((items[idx].id ?? items[idx].text).uppercased()).filter { !$0.isWhitespace })
            guard token.count > prefix.count, String(token.prefix(prefix.count)) == prefix else { continue }
            let tail = Array(token.dropFirst(prefix.count))
            let landings = Set(expandOCRDigits(tail).compactMap { Int($0) }).intersection(gapSet)
            if landings.count == 1, let g = landings.first {
                ocrMatched.append((idx, g, String(token)))
            }
        }

        let usedGapsCounts = Dictionary(ocrMatched.map { ($0.gap, 1) }, uniquingKeysWith: +)
        var resolvedByOCR = Set<Int>()
        for m in ocrMatched where usedGapsCounts[m.gap] == 1 {
            items[m.idx].suggestedId = "\(prefix)\(m.gap)"
            items[m.idx].fixRule = "ocr-confusion"
            items[m.idx].fixReason = "OCR substitution on \"\(m.raw)\" lands uniquely on gap \(prefix)\(m.gap)"
            gapSet.remove(m.gap)
            resolvedByOCR.insert(m.idx)
            known.append((m.idx, m.gap))
            ruleCounts["ocr-confusion", default: 0] += 1
        }

        let leftCandidates = unresolved.filter { !resolvedByOCR.contains($0) }
        let leftGaps = gapSet.sorted()
        guard !leftGaps.isEmpty, leftCandidates.count == leftGaps.count else { continue }

        if leftCandidates.count == 1 {
            let idx = leftCandidates[0], g = leftGaps[0]
            items[idx].suggestedId = "\(prefix)\(g)"
            items[idx].fixRule = "id-sequence"
            items[idx].fixReason = "sole candidate in class assigned sole missing number \(prefix)\(g)"
            ruleCounts["id-sequence", default: 0] += 1
        } else if let assigned = assignMonotoneSequence(
            known: known, candidates: leftCandidates, gaps: leftGaps, items: items
        ) {
            for a in assigned {
                items[a.idx].suggestedId = "\(prefix)\(a.gap)"
                items[a.idx].fixRule = "id-sequence"
                items[a.idx].fixReason = "assigned \(prefix)\(a.gap) by \(a.axisDesc) position"
                ruleCounts["id-sequence", default: 0] += 1
            }
        }
    }
}

struct Options {
    var planPath: String
    var legendPath: String
    var outDir: String = "output/swift4/plan1"
    var repair: Bool = true
    var reread: Bool = true
    var bridge: Bool = true
    var regroup: Bool = true
    var featurePrint: Bool = false
    var judgeMode: String = "off"
}

func parseOptions(_ args: [String]) -> Options? {
    var positional: [String] = []
    var outDir = "output/swift4/plan1"
    var repair = true
    var reread = true
    var bridge = true
    var regroup = true
    var featurePrint = false
    var judgeMode = "off"

    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--out":
            guard i + 1 < args.count else { return nil }
            outDir = args[i + 1]
            i += 2
        case "--no-repair":
            repair = false
            i += 1
        case "--no-reread":
            reread = false
            i += 1
        case "--no-bridge":
            bridge = false
            i += 1
        case "--no-regroup":
            regroup = false
            i += 1
        case "--feature-print":
            featurePrint = true
            i += 1
        case "--judge":
            guard i + 1 < args.count, ["off", "fm", "mlx"].contains(args[i + 1]) else { return nil }
            judgeMode = args[i + 1]
            i += 2
        default:
            if arg.hasPrefix("--") { return nil }
            positional.append(arg)
            i += 1
        }
    }
    guard positional.count == 2 else { return nil }
    return Options(
        planPath: positional[0], legendPath: positional[1], outDir: outDir,
        repair: repair, reread: reread, bridge: bridge, regroup: regroup,
        featurePrint: featurePrint, judgeMode: judgeMode
    )
}

@main
struct Tool {
    static func main() async throws {
        guard let opts = parseOptions(CommandLine.arguments) else {
            fputs("usage: extract_swift4 layout.png legend.png [--out dir] [--no-repair] [--no-reread] [--no-bridge] [--no-regroup] [--feature-print] [--judge off|fm|mlx]\n", stderr)
            exit(2)
        }
        let outDir = URL(fileURLWithPath: opts.outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let planImage = try loadImage(URL(fileURLWithPath: opts.planPath))
        let legendImage = try loadImage(URL(fileURLWithPath: opts.legendPath))
        let classes = try await readLegend(legendImage)
        guard !classes.isEmpty else { throw ExtractError.noLegend }
        for warning in legendWarnings(classes) {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }

        let px = pixels(of: planImage)
        let (w, h) = (px.width, px.height)
        let scale = Double(max(w, h)) / 2000

        let legendOut = try await legendLayer(planImage, px, legend: classes)
        var legendItems = legendOut.items
        legendItems += await outlinedLayer(planImage, px, existing: legendItems)

        var claimed = [Bool](repeating: false, count: w * h)
        let largeTile = { (item: Item) in item.rect.width * item.rect.height > 0.01 * Double(w * h) }
        for item in legendItems where !largeTile(item) {
            fillRect(&claimed, item.rect.insetBy(dx: -6 * scale, dy: -6 * scale), w: w, h: h, value: true)
        }
        var outside = await outsideLayer(planImage, px, claimed: claimed)
        outside.removeAll { item in
            guard item.cls == "object" || item.cls == "pillar" else { return false }
            let center = CGPoint(x: item.rect.midX, y: item.rect.midY)
            return legendItems.contains { !largeTile($0) && $0.rect.contains(center) }
        }

        var swift3Baseline = legendItems + outside
        swift3Baseline.sort { ($0.box[1], $0.box[0]) < ($1.box[1], $1.box[0]) }
        let swift3Rep = report(swift3Baseline)
        let flaggedBefore = swift3Baseline.filter(\.needsReview).count

        var ruleCounts: [String: Int] = [:]
        let rereadStats = try await rereadTiles(
            planImage, items: &legendItems, labelledClasses: legendOut.labelledClasses,
            colorReasons: legendOut.colorReasons, outDir: outDir, apply: opts.reread,
            ruleCounts: &ruleCounts
        )

        var items = legendItems + outside
        if opts.bridge {
            bridgeWalls(&items, width: w, height: h, ruleCounts: &ruleCounts)
        }

        let fpStats = await regroupObjects(
            planImage, items: &items, enableModule: opts.regroup,
            enableFeaturePrint: opts.featurePrint, ruleCounts: &ruleCounts
        )

        items.sort { ($0.box[1], $0.box[0]) < ($1.box[1], $1.box[0]) }
        let classPrefixes = computeClassPrefixes(items)
        let gapIdsByClass = computeUnresolvedGapIds(items: items, classPrefixes: classPrefixes)

        if opts.repair {
            repairIds(&items, classPrefixes: classPrefixes, ruleCounts: &ruleCounts)
        }

        let entries = classes.map {
            LegendEntry(label: $0.name, colors: [[Int($0.rgb.0), Int($0.rgb.1), Int($0.rgb.2)]], prefix: boothPrefix($0.name))
        }

        let judgeRep = await runJudge(
            image: planImage, items: items, legend: entries,
            gapIdsByClass: gapIdsByClass, mode: opts.judgeMode, outDir: outDir
        )

        let swift4Rep = report(items)
        let result = Result(image: ImageInfo(width: w, height: h), legend: entries, items: items, report: swift4Rep)

        let suggestions: [SuggestedFix] = items.compactMap { it in
            guard let s = it.suggestedId else { return nil }
            return SuggestedFix(
                cls: it.cls, box: it.box, currentId: it.id, text: it.text,
                suggestedId: s, rule: it.fixRule ?? "", reason: it.fixReason ?? ""
            )
        }

        let diffReport = DiffReport(
            swift3ItemsPerClass: swift3Rep.itemsPerClass,
            swift4ItemsPerClass: swift4Rep.itemsPerClass,
            swift3IdsRead: swift3Rep.idsRead,
            swift4IdsRead: swift4Rep.idsRead,
            flaggedBefore: flaggedBefore,
            flaggedAfter: items.filter(\.needsReview).count,
            blankTiles: rereadStats,
            idsSuggested: suggestions,
            ruleCounts: ruleCounts,
            featurePrint: fpStats,
            judge: judgeRep
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: outDir.appendingPathComponent("layout.json"))
        try encoder.encode(diffReport).write(to: outDir.appendingPathComponent("report_diff.json"))
        writeOverlay(planImage, items: items, to: outDir.appendingPathComponent("overlay.png"))
        print(String(decoding: try encoder.encode(swift4Rep), as: UTF8.self))
    }
}
