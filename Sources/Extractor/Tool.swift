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

public enum ExtractTool {
    public static func run(arguments: [String]) async throws {
        guard let opts = parseOptions(arguments) else {
            fputs("usage: fp-extract layout.png legend.png [--out dir] [--no-repair] [--no-reread] [--no-bridge] [--no-regroup] [--feature-print] [--judge off|fm|mlx]\n", stderr)
            exit(2)
        }
        let outDir = URL(fileURLWithPath: opts.outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let planImage = try loadImage(URL(fileURLWithPath: opts.planPath))
        let legendImage = try loadImage(URL(fileURLWithPath: opts.legendPath))
        let legendClasses = try await readLegend(legendImage)
        guard !legendClasses.isEmpty else { throw ExtractError.noLegend }
        for warning in legendWarnings(legendClasses) {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }

        let px = pixels(of: planImage)
        var classes = legendClasses
        let (w, h) = (px.width, px.height)
        let scale = Double(max(w, h)) / 2000

        var legendOut = try await legendLayer(planImage, px, legend: classes)
        let silent = classes.indices.filter { k in !legendOut.items.contains { $0.cls == classes[k].name } }
        let adapted = adaptLegendToPlan(classes, px, classes: silent)
        if adapted.indices.contains(where: { adapted[$0].lab.l != classes[$0].lab.l || adapted[$0].lab.a != classes[$0].lab.a }) {
            classes = adapted
            legendOut = try await legendLayer(planImage, px, legend: classes)
        }
        var legendItems = legendOut.items
        legendItems += await outlinedLayer(planImage, px, existing: legendItems, scale: legendOut.scale)

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
            repairIdsByPrefix(&items, ruleCounts: &ruleCounts)
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
