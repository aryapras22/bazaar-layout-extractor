import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

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
