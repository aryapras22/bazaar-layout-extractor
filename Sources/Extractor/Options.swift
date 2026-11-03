import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Everything a run is told on the command line.
struct Options {
    var planPath: String
    var legendPath: String
    var outDir: String
    var repair: Bool = true
    var reread: Bool = true
    var bridge: Bool = true
    var regroup: Bool = true
    var featurePrint: Bool = false
    var judgeMode: String = "off"
    var layers: Set<Layer> = Set(Layer.allCases)
    var upscaleSmall: Bool = false
    var verifyDoors: Bool = false
    var modelIds: Bool = false
    var vlmFix: String = "off"
}

/// Without --out, a plan at data/plan3/layout.png writes to output/extractor/plan3.
func defaultOutDir(for planPath: String) -> String {
    let folder = URL(fileURLWithPath: planPath).deletingLastPathComponent().lastPathComponent
    return "output/extractor/" + (folder.isEmpty ? "plan" : folder)
}

let usage = "usage: fp-extract layout.png legend.png [--out dir] [--no-repair] [--no-reread] [--no-bridge] [--no-regroup] [--feature-print] [--judge off|fm|mlx] [--layers booth,wall,door,seat] [--upscale-small] [--verify-doors] [--model-ids] [--vlm-fix off|fm|mlx]\n"

func parseOptions(_ args: [String]) -> Options? {
    var positional: [String] = []
    var outDir: String?
    var repair = true
    var reread = true
    var bridge = true
    var regroup = true
    var featurePrint = false
    var judgeMode = "off"
    var layers = Set(Layer.allCases)
    var upscaleSmall = false
    var verifyDoors = false
    var modelIds = false
    var vlmFix = "off"

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
        case "--verify-doors":
            verifyDoors = true
            i += 1
        case "--vlm-fix":
            guard i + 1 < args.count, ["off", "fm", "mlx"].contains(args[i + 1]) else { return nil }
            vlmFix = args[i + 1]
            i += 2
        case "--model-ids":
            modelIds = true
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
        planPath: positional[0], legendPath: positional[1], outDir: outDir ?? defaultOutDir(for: positional[0]),
        repair: repair, reread: reread, bridge: bridge, regroup: regroup,
        featurePrint: featurePrint, judgeMode: judgeMode, layers: layers, upscaleSmall: upscaleSmall,
        verifyDoors: verifyDoors, modelIds: modelIds, vlmFix: vlmFix
    )
}
