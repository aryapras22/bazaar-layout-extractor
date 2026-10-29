import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct Options {
    var planPath: String
    var legendPath: String
    var outDir: String = "output/swift5/plan1"
    var repair: Bool = true
    var reread: Bool = true
    var bridge: Bool = true
    var regroup: Bool = true
    var featurePrint: Bool = false
    var judgeMode: String = "off"
    var layers: Set<Layer> = Set(Layer.allCases)
    var upscaleSmall: Bool = false
}

func parseOptions(_ args: [String]) -> Options? {
    var positional: [String] = []
    var outDir = "output/swift5/plan1"
    var repair = true
    var reread = true
    var bridge = true
    var regroup = true
    var featurePrint = false
    var judgeMode = "off"
    var layers = Set(Layer.allCases)
    var upscaleSmall = false

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
        case "--upscale-small":
            upscaleSmall = true
            i += 1
        case "--layers":
            guard i + 1 < args.count else { return nil }
            let named = args[i + 1].split(separator: ",").map { Layer(rawValue: String($0)) }
            guard !named.isEmpty, !named.contains(nil) else { return nil }
            layers = Set(named.compactMap { $0 })
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
        featurePrint: featurePrint, judgeMode: judgeMode, layers: layers, upscaleSmall: upscaleSmall
    )
}

public enum ExtractTool {
    public static func run(arguments: [String]) async throws {
        guard let opts = parseOptions(arguments) else {
            fputs("usage: fp-extract layout.png legend.png [--out dir] [--no-repair] [--no-reread] [--no-bridge] [--no-regroup] [--feature-print] [--judge off|fm|mlx] [--layers booth,wall,door,seat] [--upscale-small]\n", stderr)
            exit(2)
        }
        let outDir = URL(fileURLWithPath: opts.outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let originalImage = try loadImage(URL(fileURLWithPath: opts.planPath))
        var planImage = originalImage
        var legendImage = try loadImage(URL(fileURLWithPath: opts.legendPath))
        if let clean = smoothedIfNoisy(legendImage, threshold: 0.04) {
            FileHandle.standardError.write(Data("note: pixel noise found in the legend, smoothing it before reading it\n".utf8))
            legendImage = clean
        }
        let legendClasses = try await readLegend(legendImage)
        guard !legendClasses.isEmpty else { throw ExtractError.noLegend }
        for warning in legendWarnings(legendClasses) {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }

        if let clean = smoothedIfNoisy(planImage, threshold: 0.07) {
            FileHandle.standardError.write(Data("note: pixel noise found, smoothing the plan before reading it\n".utf8))
            planImage = clean
        }
        var px = pixels(of: planImage)
        // Small tiles are read badly by Vision and fall under the size thresholds, so --upscale-small enlarges the plan.
        // Off by default: it lifts plan 5 and half-size plan 2, but breaks plan 6 when it is faded or halved,
        // because the fixed outline cut loses lines that resampling lightens.
        let tileSide = opts.upscaleSmall
            ? smallTileSide(classify(px, legend: legendClasses), w: px.width, h: px.height, area: px.area) : nil
        let upscale = upscaleFactor(smallTileSide: tileSide)
        if upscale > 1, let bigger = upscaled(planImage, by: upscale) {
            FileHandle.standardError.write(Data("note: tiles are small, reading the plan at \(upscale)x\n".utf8))
            planImage = bigger
            px = pixels(of: planImage)
        }
        var classes = legendClasses
        let (w, h) = (px.width, px.height)
        let scale = Double(px.page) / 2000

        var legendOut = try await legendLayer(planImage, px, legend: classes)
        // A class whose colour is far from the plan's (faded print, other screen) finds few tiles, or only the tiles
        // that happen to sit inside the gate, so every class is checked against the plan's colours.
        let adapted = adaptLegendToPlan(classes, px, classes: Array(classes.indices))
        if adapted.indices.contains(where: { adapted[$0].lab.l != classes[$0].lab.l || adapted[$0].lab.a != classes[$0].lab.a }) {
            classes = adapted
            legendOut = try await legendLayer(planImage, px, legend: classes)
        }
        var legendItems = legendOut.items
        legendItems += await outlinedLayer(planImage, px, existing: legendItems, scale: legendOut.scale, lineScale: upscale)

        var claimed = [Bool](repeating: false, count: w * h)
        let largeTile = { (item: Item) in item.rect.width * item.rect.height > 0.01 * Double(px.area) }
        for item in legendItems where !largeTile(item) {
            fillRect(&claimed, item.rect.insetBy(dx: -6 * scale, dy: -6 * scale), w: w, h: h, value: true)
        }
        // The booth layer needs nothing from the others, so a booth-only run skips the ink analysis.
        var outside = opts.layers.isDisjoint(with: [.wall, .door, .seat])
            ? [] : await outsideLayers(planImage, px, claimed: claimed).all
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
            planImage, content: px.contentRect, items: &legendItems, labelledClasses: legendOut.labelledClasses,
            colorReasons: legendOut.colorReasons, outDir: outDir, apply: opts.reread,
            ruleCounts: &ruleCounts
        )

        var items = legendItems + outside
        if opts.bridge {
            bridgeWalls(&items, page: px.page, ruleCounts: &ruleCounts)
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
            repairIdsByPrefix(&items, ruleCounts: &ruleCounts)
        }

        let entries = classes.map {
            LegendEntry(label: $0.name, colors: [[Int($0.rgb.0), Int($0.rgb.1), Int($0.rgb.2)]], prefix: boothPrefix($0.name))
        }

        let judgeRep = await runJudge(
            image: planImage, items: items, legend: entries,
            gapIdsByClass: gapIdsByClass, mode: opts.judgeMode, outDir: outDir
        )

        for entry in judgeRep.entries where entry.accepted && items.indices.contains(entry.itemIndex) {
            if items[entry.itemIndex].cls == "object", let choice = entry.judgeChoice {
                items[entry.itemIndex].seat = seatLabels.contains(choice)
            }
        }

        items = items.map { scaledBack($0, by: upscale) }.filter { opts.layers.contains(Layer.of($0)) }

        let swift4Rep = report(items)
        let result = Result(image: ImageInfo(width: originalImage.width, height: originalImage.height), legend: entries, items: items, report: swift4Rep)

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
        for layer in opts.layers.sorted() {
            let file = LayerFile(layer: layer.rawValue, image: ImageInfo(width: originalImage.width, height: originalImage.height), items: items.filter { Layer.of($0) == layer })
            try encoder.encode(file).write(to: outDir.appendingPathComponent(layer.file))
        }
        writeOverlay(originalImage, items: items, to: outDir.appendingPathComponent("overlay.png"))
        print(String(decoding: try encoder.encode(swift4Rep), as: UTF8.self))
    }
}
