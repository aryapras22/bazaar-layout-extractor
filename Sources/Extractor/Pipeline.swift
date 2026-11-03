import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// One run over one plan. The stages below run in the order `ExtractTool.run` lists them, and each one reads what
/// the earlier ones left on this object. To improve one pipeline, change its stage and read its scores:
///
///   load      read the plan and legend, clean noise, enlarge small prints
///   booths    booth layer: legend colours and outlines give the tiles
///   outside   wall, door and seat layers: the ink that is not a booth, text or label
///   ids       reread blank tiles, bridge walls, regroup objects, repair the booth IDs
///   review    judge, VLM fix and door check: second opinions that flag or drop items
///   write     layout.json, one file per layer, the diff report and the overlay
final class PlanRun {
    let opts: Options
    let outDir: URL
    let originalImage: CGImage
    var planImage: CGImage
    var px: Pixels
    var classes: [LegendClass]
    var upscale = 1

    // Set by the stage named in the comment; the stages always run in order, so later stages may rely on them.
    var legendOut: LegendLayerOutput!      // booths
    var booths: [Item] = []
    var outside: [Item] = []
    var items: [Item] = []
    var ruleCounts: [String: Int] = [:]

    var baseline: Report!                  // outside
    var flaggedBefore = 0
    var rereadStats: RereadStats!          // ids
    var featurePrint: FeaturePrintStats!   // ids
    var classPrefixes: [String: String] = [:]
    var gapIdsByClass: [String: [String]] = [:]
    var entries: [LegendEntry] = []
    var judgeReport: JudgeReport!          // review
    var vlmFix: VlmFixReport?

    init(opts: Options, outDir: URL, original: CGImage, plan: CGImage, px: Pixels, classes: [LegendClass]) {
        self.opts = opts
        self.outDir = outDir
        self.originalImage = original
        self.planImage = plan
        self.px = px
        self.classes = classes
    }

    static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    // MARK: load

    static func load(_ opts: Options) async throws -> PlanRun {
        let outDir = URL(fileURLWithPath: opts.outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let original = try loadImage(URL(fileURLWithPath: opts.planPath))
        var plan = original
        var legendImage = try loadImage(URL(fileURLWithPath: opts.legendPath))
        if let clean = smoothedIfNoisy(legendImage, threshold: 0.04) {
            note("note: pixel noise found in the legend, smoothing it before reading it")
            legendImage = clean
        }
        let legendClasses = try await readLegend(legendImage)
        guard !legendClasses.isEmpty else { throw ExtractError.noLegend }
        for warning in legendWarnings(legendClasses) { note("warning: \(warning)") }

        if let clean = smoothedIfNoisy(plan, threshold: 0.07) {
            note("note: pixel noise found, smoothing the plan before reading it")
            plan = clean
        }
        var px = pixels(of: plan)
        // Small tiles are read badly by Vision and fall under the size thresholds, so --upscale-small enlarges the plan.
        // Off by default: it lifts plan 5 and half-size plan 2, but breaks plan 6 when it is faded or halved,
        // because the fixed outline cut loses lines that resampling lightens.
        let tileSide = opts.upscaleSmall
            ? smallTileSide(classify(px, legend: legendClasses), w: px.width, h: px.height, area: px.area) : nil
        let run = PlanRun(opts: opts, outDir: outDir, original: original, plan: plan, px: px, classes: legendClasses)
        run.upscale = upscaleFactor(smallTileSide: tileSide)
        if run.upscale > 1, let bigger = upscaled(plan, by: run.upscale) {
            note("note: tiles are small, reading the plan at \(run.upscale)x")
            px = pixels(of: bigger)
            run.planImage = bigger
            run.px = px
        }
        return run
    }

    // MARK: booths

    /// Tiles from the legend colours and from outlines. Their boxes are claimed so no other layer reads them again.
    func findBooths() async throws -> [Bool] {
        var legendOut = try await legendLayer(planImage, px, legend: classes)
        // A class whose colour is far from the plan's (faded print, other screen) finds few tiles, or only the tiles
        // that happen to sit inside the gate, so every class is checked against the plan's colours.
        let adapted = adaptLegendToPlan(classes, px, classes: Array(classes.indices))
        if adapted.indices.contains(where: { adapted[$0].lab.l != classes[$0].lab.l || adapted[$0].lab.a != classes[$0].lab.a }) {
            classes = adapted
            legendOut = try await legendLayer(planImage, px, legend: classes)
        }
        self.legendOut = legendOut
        booths = legendOut.items
        booths += await outlinedLayer(planImage, px, existing: booths, scale: legendOut.scale, lineScale: upscale)

        var claimed = [Bool](repeating: false, count: px.width * px.height)
        let scale = Double(px.page) / 2000
        for item in booths where !isLarge(item) {
            fillRect(&claimed, item.rect.insetBy(dx: -6 * scale, dy: -6 * scale), w: px.width, h: px.height, value: true)
        }
        return claimed
    }

    private func isLarge(_ item: Item) -> Bool {
        item.rect.width * item.rect.height > 0.01 * Double(px.area)
    }

    // MARK: outside

    /// Wall, door and seat layers. The booth layer needs nothing from the others, so a booth-only run skips the ink analysis.
    func findOutside(claimed: [Bool]) async {
        outside = opts.layers.isDisjoint(with: [.wall, .door, .seat])
            ? [] : await outsideLayers(planImage, px, claimed: claimed).all
        outside.removeAll { item in
            guard item.cls == "object" || item.cls == "pillar" else { return false }
            let center = CGPoint(x: item.rect.midX, y: item.rect.midY)
            return booths.contains { !isLarge($0) && $0.rect.contains(center) }
        }
        var first = booths + outside
        first.sort { ($0.box[1], $0.box[0]) < ($1.box[1], $1.box[0]) }
        baseline = report(first)
        flaggedBefore = first.filter(\.needsReview).count
    }

    // MARK: ids

    /// Blank tiles are read again, walls are bridged across gaps, objects regrouped, and booth IDs repaired from their numbering.
    func readIds() async throws {
        rereadStats = try await rereadTiles(
            planImage, content: px.contentRect, items: &booths, labelledClasses: legendOut.labelledClasses,
            colorReasons: legendOut.colorReasons, outDir: outDir, apply: opts.reread,
            ruleCounts: &ruleCounts)

        items = booths + outside
        if opts.bridge { bridgeWalls(&items, page: px.page, ruleCounts: &ruleCounts) }

        featurePrint = await regroupObjects(
            planImage, items: &items, enableModule: opts.regroup,
            enableFeaturePrint: opts.featurePrint, ruleCounts: &ruleCounts)

        items.sort { ($0.box[1], $0.box[0]) < ($1.box[1], $1.box[0]) }
        classPrefixes = computeClassPrefixes(items)
        gapIdsByClass = computeUnresolvedGapIds(items: items, classPrefixes: classPrefixes)

        if opts.repair {
            repairIds(&items, classPrefixes: classPrefixes, ruleCounts: &ruleCounts)
            repairIdsByPrefix(&items, ruleCounts: &ruleCounts)
        }
        if opts.modelIds {
            let read = readMissingIdsWithModel(
                image: planImage, items: &items, classPrefixes: classPrefixes, gapIdsByClass: gapIdsByClass,
                outDir: outDir, ruleCounts: &ruleCounts)
            Self.note("note: the local model supplied \(read) tile IDs")
        }
        entries = classes.map {
            LegendEntry(label: $0.name, colors: [[Int($0.rgb.0), Int($0.rgb.1), Int($0.rgb.2)]], prefix: boothPrefix($0.name))
        }
    }

    // MARK: review

    /// Second opinions. The judge flags seats, the door check drops unconfirmed swing symbols, the VLM proposes fixes.
    func review() async {
        let judged = await runJudge(
            image: planImage, items: items, legend: entries,
            gapIdsByClass: gapIdsByClass, mode: opts.judgeMode, outDir: outDir)
        judgeReport = judged
        for entry in judged.entries where entry.accepted && items.indices.contains(entry.itemIndex) {
            if items[entry.itemIndex].cls == "object", let choice = entry.judgeChoice {
                items[entry.itemIndex].seat = (items[entry.itemIndex].seat ?? false) || seatLabels.contains(choice)
            }
        }

        items = items.map { scaledBack($0, by: upscale) }.filter { opts.layers.contains(Layer.of($0)) }
        if opts.verifyDoors { dropUnconfirmedDoors(&items, planPath: opts.planPath, outDir: outDir) }
        if opts.vlmFix != "off" {
            vlmFix = await runVlmFix(
                image: originalImage, items: items, classNames: classes.map(\.name), backend: opts.vlmFix, outDir: outDir)
        }
    }

    // MARK: write

    /// layout.json (everything), one file per layer, report_diff.json, overlay.png, and the final report on stdout.
    func write() throws {
        let final = report(items)
        let info = ImageInfo(width: originalImage.width, height: originalImage.height)
        let result = Result(image: info, legend: entries, items: items, report: final)

        let suggestions: [SuggestedFix] = items.compactMap { it in
            guard let s = it.suggestedId else { return nil }
            return SuggestedFix(
                cls: it.cls, box: it.box, currentId: it.id, text: it.text,
                suggestedId: s, rule: it.fixRule ?? "", reason: it.fixReason ?? "")
        }
        let diff = DiffReport(
            baselineItemsPerClass: baseline.itemsPerClass,
            itemsPerClass: final.itemsPerClass,
            baselineIdsRead: baseline.idsRead,
            idsRead: final.idsRead,
            flaggedBefore: flaggedBefore,
            flaggedAfter: items.filter(\.needsReview).count,
            blankTiles: rereadStats,
            idsSuggested: suggestions,
            ruleCounts: ruleCounts,
            featurePrint: featurePrint,
            judge: judgeReport)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: outDir.appendingPathComponent("layout.json"))
        try encoder.encode(diff).write(to: outDir.appendingPathComponent("report_diff.json"))
        if let vlmFix {
            try encoder.encode(vlmFix).write(to: outDir.appendingPathComponent("vlm_fix.json"))
            let valid = vlmFix.proposals.filter { $0.valid && $0.action != "keep" }.count
            Self.note("note: vlm fix (\(vlmFix.status)) checked \(vlmFix.proposals.count) items, proposed \(valid) changes")
        }
        for layer in opts.layers.sorted() {
            let file = LayerFile(layer: layer.rawValue, image: info, items: items.filter { Layer.of($0) == layer })
            try encoder.encode(file).write(to: outDir.appendingPathComponent(layer.file))
        }
        writeOverlay(originalImage, items: items, to: outDir.appendingPathComponent("overlay.png"))
        print(String(decoding: try encoder.encode(final), as: UTF8.self))
    }
}
