import Foundation

public struct LayoutItem: Codable, Equatable {
    public var cls: String
    public var box: [Int]
    public var area: Int
    public var fillRgb: [Int]
    public var legendRgb: [Int]
    public var text: String
    public var id: String?
    public var needsReview: Bool
    public var reason: String?
    public var polygon: [[Int]]?
    public var source: String?
    public var fillBox: [Int]?
    public var suggestedId: String?
    public var fixRule: String?
    public var fixReason: String?

    enum CodingKeys: String, CodingKey {
        case cls = "class", box, area, fillRgb = "fill_rgb", legendRgb = "legend_rgb", text, id
        case needsReview = "needs_review", reason, polygon, source, fillBox = "fill_box"
        case suggestedId = "suggested_id", fixRule = "fix_rule", fixReason = "fix_reason"
    }

    public init(
        cls: String, box: [Int], area: Int? = nil, fillRgb: [Int] = [128, 128, 128],
        legendRgb: [Int] = [128, 128, 128], text: String = "", id: String? = nil,
        needsReview: Bool = true, reason: String? = nil, polygon: [[Int]]? = nil
    ) {
        self.cls = cls
        self.box = box
        self.area = area ?? box[2] * box[3]
        self.fillRgb = fillRgb
        self.legendRgb = legendRgb
        self.text = text
        self.id = id
        self.needsReview = needsReview
        self.reason = reason
        self.polygon = polygon
    }

    // The notebook render cell indexes it["id"], so a missing ID must stay an explicit null.
    public func encode(to encoder: Encoder) throws {
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

    var centerX: Double { Double(box[0]) + Double(box[2]) / 2 }
    var centerY: Double { Double(box[1]) + Double(box[3]) / 2 }
    var shortSide: Double { Double(min(box[2], box[3])) }
    var longSide: Double { Double(max(box[2], box[3])) }
}

public struct ImageInfo: Codable, Equatable {
    public var width: Int
    public var height: Int
    public var unit: String
    public var origin: String
}

public enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// legend and report pass through untouched; repair never changes them.
public struct Layout: Codable {
    public var image: ImageInfo
    public var legend: JSONValue
    public var items: [LayoutItem]
    public var report: JSONValue
}
