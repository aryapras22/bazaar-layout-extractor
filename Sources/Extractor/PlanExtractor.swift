import CoreGraphics
import Foundation

/// A legend swatch as read from the legend image.
public struct LegendSwatch: Sendable {
    public let label: String
    public let rgb: [Int]
}

/// One thing found on the plan, in pixels of the image that was passed in. `kind` and `cls` are the extractor's own
/// words ("booth classes" are the legend labels, then `wall`, `pillar`, `door`, `opening`, `object`).
public struct PlanItem: Sendable {
    public let cls: String
    public let box: [Int]
    public let id: String?
    public let needsReview: Bool
    public let segment: [Int]?
    public let width: Double?
    public let kind: String?
    /// The legend colour of the class this item was matched to, or grey for items that are not legend classes.
    public let legendRgb: [Int]
    public let chairs: Int?
    public let symbolClass: String?
    public let symbolScore: Double?

    public init(
        cls: String,
        box: [Int],
        id: String? = nil,
        needsReview: Bool = false,
        segment: [Int]? = nil,
        width: Double? = nil,
        kind: String? = nil,
        legendRgb: [Int] = [128, 128, 128],
        chairs: Int? = nil,
        symbolClass: String? = nil,
        symbolScore: Double? = nil
    ) {
        self.cls = cls
        self.box = box
        self.id = id
        self.needsReview = needsReview
        self.segment = segment
        self.width = width
        self.kind = kind
        self.legendRgb = legendRgb
        self.chairs = chairs
        self.symbolClass = symbolClass
        self.symbolScore = symbolScore
    }
}

public struct PlanReading: Sendable {
    public let imageWidth: Int
    public let imageHeight: Int
    public let legend: [LegendSwatch]
    public let items: [PlanItem]
}

/// In-memory entry point for an app: images in, items out, nothing written to disk except scratch crops that are
/// deleted again. The second-opinion options that start a Python process or a model stay off.
public enum PlanExtractor {
    public static func legend(in image: CGImage) async throws -> [LegendSwatch] {
        let image = smoothedIfNoisy(image, threshold: 0.04) ?? image
        let classes = try await readLegend(image)
        guard !classes.isEmpty else { throw ExtractError.noLegend }
        return classes.map { LegendSwatch(label: $0.name, rgb: [Int($0.rgb.0), Int($0.rgb.1), Int($0.rgb.2)]) }
    }

    /// `onProgress` is called after each stage with a value from 0 to 1.
    public static func plan(
        _ plan: CGImage,
        legend: CGImage,
        symbols: SymbolLegend = .empty,
        onProgress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> PlanReading {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("plan-extractor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var opts = Options(planPath: "", legendPath: "", outDir: scratch.path)
        opts.judgeMode = "off"
        opts.vlmFix = "off"
        let run = try await PlanRun.load(opts, outDir: scratch, original: plan, legend: legend, symbols: symbols)
        onProgress(0.1)
        let claimed = try await run.findBooths()
        onProgress(0.4)
        await run.findOutside(claimed: claimed)
        onProgress(0.7)
        try await run.readIds()
        onProgress(0.9)
        await run.review()
        onProgress(1)

        let items = run.items.map {
            PlanItem(cls: $0.cls, box: $0.box, id: $0.id, needsReview: $0.needsReview,
                     segment: $0.segment, width: $0.width, kind: $0.kind, legendRgb: $0.legendRgb,
                     chairs: $0.chairs, symbolClass: $0.symbolClass, symbolScore: $0.symbolScore)
        }
        let swatches = run.entries.map { LegendSwatch(label: $0.label, rgb: $0.colors.first ?? [128, 128, 128]) }
        return PlanReading(imageWidth: plan.width, imageHeight: plan.height, legend: swatches, items: items)
    }
}
