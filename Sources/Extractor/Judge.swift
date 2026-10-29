import CoreGraphics
import CoreText
import CryptoKit
import Foundation

struct JudgeEntry: Codable {
    var itemIndex: Int
    var number: Int
    var cls: String
    var box: [Int]
    var ruleSuggestedId: String?
    var judgeChoice: String?
    var accepted: Bool
    var agreedWithRule: Bool?
    var fromCache: Bool

    enum CodingKeys: String, CodingKey {
        case itemIndex = "item_index"
        case number
        case cls = "class"
        case box
        case ruleSuggestedId = "rule_suggested_id"
        case judgeChoice = "judge_choice"
        case accepted
        case agreedWithRule = "agreed_with_rule"
        case fromCache = "from_cache"
    }
}

struct JudgeReport: Codable {
    var mode: String
    var status: String
    var flaggedItemsEvaluated: Int
    var uniqueRequests: Int
    var cacheHits: Int
    var acceptedAnswers: Int
    var comparedWithRule: Int
    var agreedWithRule: Int
    var agreementRate: Double?
    var entries: [JudgeEntry]

    enum CodingKeys: String, CodingKey {
        case mode
        case status
        case flaggedItemsEvaluated = "flagged_items_evaluated"
        case uniqueRequests = "unique_requests"
        case cacheHits = "cache_hits"
        case acceptedAnswers = "accepted_answers"
        case comparedWithRule = "compared_with_rule"
        case agreedWithRule = "agreed_with_rule"
        case agreementRate = "agreement_rate"
        case entries
    }
}

let seatLabels: Set<String> = ["table_with_chairs", "audience_seating"]

let structuralGroupLabels = [
    "table_with_chairs", "audience_seating", "stairs", "door", "pillar", "wall", "noise"
]

private func makeJudgeCrop(_ image: CGImage, item: Item) -> (rawBytes: Data, baseImage: CGImage)? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let box = item.box
    let rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3]).intersection(bounds).integral
    guard rect.width >= 1, rect.height >= 1, let sub = image.cropping(to: rect) else { return nil }
    let targetMin = max(64.0, 0.06 * Double(max(image.width, image.height)))
    let curMin = Double(min(sub.width, sub.height))
    let scale = max(1, min(4, Int((targetMin / max(1.0, curMin)).rounded(.up))))
    let w = sub.width * scale
    let h = sub.height * scale
    var bytes = Data(count: w * h * 4)
    let rendered: CGImage? = bytes.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(
            data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        if let poly = item.polygon, poly.count >= 3 {
            let path = CGMutablePath()
            for (idx, pt) in poly.enumerated() {
                let px = CGFloat(Double(pt[0]) - Double(rect.minX)) * CGFloat(scale)
                let py = CGFloat(Double(rect.height) - (Double(pt[1]) - Double(rect.minY))) * CGFloat(scale)
                if idx == 0 { path.move(to: CGPoint(x: px, y: py)) }
                else { path.addLine(to: CGPoint(x: px, y: py)) }
            }
            path.closeSubpath()
            ctx.addPath(path)
            ctx.clip()
        }
        ctx.interpolationQuality = .high
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
        return ctx.makeImage()
    }
    guard let baseImage = rendered else { return nil }
    return (bytes, baseImage)
}

private func makeCompositeGroupCrop(_ image: CGImage, box: [Int]) -> CGImage? {
    let W = image.width, H = image.height
    let bounds = CGRect(x: 0, y: 0, width: W, height: H)
    let x = box[0], y = box[1], w = box[2], h = box[3]
    let tightRect = CGRect(x: x - 4, y: y - 4, width: w + 8, height: h + 8).intersection(bounds).integral
    let pad = max(60, Int((Double(max(w, h)) * 1.2).rounded()))
    let ctxRect = CGRect(x: x - pad, y: y - pad, width: w + 2 * pad, height: h + 2 * pad).intersection(bounds).integral
    guard let tightSub = image.cropping(to: tightRect), let ctxSub = image.cropping(to: ctxRect) else { return nil }

    let side = 224
    let sep = 8
    let totalW = side * 2 + sep
    guard let ctx = CGContext(
        data: nil, width: totalW, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: side))
    ctx.setFillColor(CGColor(red: 200.0 / 255.0, green: 200.0 / 255.0, blue: 200.0 / 255.0, alpha: 1))
    ctx.fill(CGRect(x: side, y: 0, width: sep, height: side))
    ctx.interpolationQuality = .high

    func drawFitted(_ sub: CGImage, offsetX: Int, highlightBoxInSub: CGRect?) {
        let pw = Double(sub.width), ph = Double(sub.height)
        let s = min(Double(side - 16) / max(1.0, pw), Double(side - 16) / max(1.0, ph))
        let nw = max(1.0, (pw * s).rounded()), nh = max(1.0, (ph * s).rounded())
        let ox = Double(offsetX) + (Double(side) - nw) / 2.0
        let oy = (Double(side) - nh) / 2.0
        ctx.draw(sub, in: CGRect(x: ox, y: oy, width: nw, height: nh))
        if let hb = highlightBoxInSub {
            let rx = ox + Double(hb.minX) * s
            let ry = oy + (ph - Double(hb.maxY)) * s
            let rw = Double(hb.width) * s
            let rh = Double(hb.height) * s
            ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.setLineWidth(2)
            ctx.stroke(CGRect(x: rx, y: ry, width: rw, height: rh))
        }
    }

    drawFitted(tightSub, offsetX: 0, highlightBoxInSub: nil)
    let relBox = CGRect(x: CGFloat(x) - ctxRect.minX, y: CGFloat(y) - ctxRect.minY, width: CGFloat(w), height: CGFloat(h))
    drawFitted(ctxSub, offsetX: side + sep, highlightBoxInSub: relBox)
    return ctx.makeImage()
}

private func badgeCrop(_ base: CGImage, number: Int) -> CGImage {
    let bannerH = max(18, base.height / 6)
    let w = base.width
    let h = base.height + bannerH
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return base }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: base.height))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(max(11, bannerH - 4)), nil)
    let attrs: [NSAttributedString.Key: Any] = [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "#\(number)", attributes: attrs))
    ctx.textPosition = CGPoint(x: 4, y: CGFloat(base.height + 3))
    CTLineDraw(line, ctx)
    return ctx.makeImage() ?? base
}

private func runMlxJudge(
    image: CGImage,
    items: [Item],
    gapIdsByClass: [String: [String]],
    outDir: URL
) -> JudgeReport {
    let pythonPath = NSHomeDirectory() + "/miniconda3/envs/floor-plan-vlm-bench/bin/python"
    guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
        return JudgeReport(
            mode: "mlx", status: "missing-env-floor-plan-vlm-bench", flaggedItemsEvaluated: 0,
            uniqueRequests: 0, cacheHits: 0, acceptedAnswers: 0, comparedWithRule: 0,
            agreedWithRule: 0, agreementRate: nil, entries: []
        )
    }

    let judgeDir = outDir.appendingPathComponent("judge_crops")
    try? FileManager.default.createDirectory(at: judgeDir, withIntermediateDirectories: true)

    struct TaskSpec: Codable {
        var key: String
        var kind: String
        var path: String
        var candidates: [String]
    }

    var tasksByKey: [String: TaskSpec] = [:]
    var orderedKeys: [String] = []
    var itemKeys: [(idx: Int, num: Int, key: String)] = []
    let allGapIds = Array(Set(gapIdsByClass.values.flatMap { $0 })).sorted()
    var number = 0

    for idx in items.indices where items[idx].needsReview {
        let item = items[idx]
        let classGaps = gapIdsByClass[item.cls] ?? []
        let usingGapSet = !classGaps.isEmpty
        guard usingGapSet || item.cls == "object" else { continue }
        number += 1

        let key: String
        let kind: String
        let candidates: [String]
        if usingGapSet {
            key = "tile_\(idx)"
            kind = "tile"
            candidates = allGapIds
        } else if let reason = item.reason, reason.hasPrefix("label this group once (") {
            key = "group_\(reason)"
            kind = "group"
            candidates = structuralGroupLabels
        } else {
            key = "obj_\(idx)"
            kind = "group"
            candidates = structuralGroupLabels
        }

        if tasksByKey[key] == nil {
            let safeName = key.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
            let cropURL = judgeDir.appendingPathComponent("\(safeName).png")
            let cropImg = kind == "tile"
                ? makeMaskedUpscaledCrop(image, item: item, scale: 3)
                : makeCompositeGroupCrop(image, box: item.box)
            if let cropImg {
                savePNG(cropImg, to: cropURL)
                tasksByKey[key] = TaskSpec(key: key, kind: kind, path: cropURL.path, candidates: candidates)
                orderedKeys.append(key)
            }
        }
        if tasksByKey[key] != nil {
            itemKeys.append((idx, number, key))
        }
    }

    guard !orderedKeys.isEmpty else {
        return JudgeReport(
            mode: "mlx", status: "ok", flaggedItemsEvaluated: 0, uniqueRequests: 0,
            cacheHits: 0, acceptedAnswers: 0, comparedWithRule: 0, agreedWithRule: 0,
            agreementRate: nil, entries: []
        )
    }

    let reqURL = judgeDir.appendingPathComponent("requests.json")
    let respURL = judgeDir.appendingPathComponent("responses.json")
    let specs = orderedKeys.compactMap { tasksByKey[$0] }
    guard let reqData = try? JSONEncoder().encode(specs), (try? reqData.write(to: reqURL)) != nil else {
        return JudgeReport(
            mode: "mlx", status: "write-requests-failed", flaggedItemsEvaluated: 0, uniqueRequests: 0,
            cacheHits: 0, acceptedAnswers: 0, comparedWithRule: 0, agreedWithRule: 0,
            agreementRate: nil, entries: []
        )
    }

    let pyCode = """
    import json, os, re, sys
    os.environ["HF_HUB_OFFLINE"] = "1"
    from mlx_vlm import load, generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import load_config
    model_id = "mlx-community/Qwen3.5-9B-MLX-4bit"
    config = load_config(model_id)
    model, proc = load(model_id)
    tasks = json.load(open(sys.argv[1]))
    out = {}
    for t in tasks:
        if t["kind"] == "group":
            p = (
                "This floor plan crop shows a zoomed shape on the left and its surrounding context with a red box on the right. "
                "Classify the red-boxed shape into ONE of these exact labels: "
                "table_with_chairs, audience_seating, stairs, door, pillar, wall, noise. "
                'Return ONLY valid JSON: {"label":"<choice>"}'
            )
        else:
            p = (
                "Read the main booth identifier printed inside this floor plan tile. "
                'Return ONLY valid JSON: {"id":"<ID>"}'
            )
        fmt = apply_chat_template(proc, config, p, num_images=1, enable_thinking=False)
        res = generate(model, proc, fmt, image=[t["path"]], temperature=0.0, max_tokens=48, verbose=False)
        s = re.sub(r"<think>.*?</think>", "", res.text, flags=re.DOTALL).strip()
        picked = None
        if t["kind"] == "group":
            for lbl in t["candidates"]:
                if lbl in s.lower():
                    picked = lbl
                    break
        else:
            m = re.search(r"\\b([A-Z]{1,2}\\d{1,3})\\b", s.upper())
            if m:
                picked = m.group(1)
        out[t["key"]] = picked
    json.dump(out, open(sys.argv[2], "w"))
    """

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: pythonPath)
    proc.arguments = ["-c", pyCode, reqURL.path, respURL.path]
    try? proc.run()
    proc.waitUntilExit()

    let answers: [String: String?] = (try? Data(contentsOf: respURL))
        .flatMap { try? JSONDecoder().decode([String: String?].self, from: $0) } ?? [:]

    var seenKeys = Set<String>()
    var entries: [JudgeEntry] = []
    var cacheHits = 0
    var acceptedAnswers = 0
    var comparedWithRule = 0
    var agreedWithRule = 0

    for (idx, num, key) in itemKeys {
        let item = items[idx]
        let fromCache = seenKeys.contains(key)
        seenKeys.insert(key)
        if fromCache { cacheHits += 1 }
        let rawChoice = answers[key] ?? nil
        let accepted = rawChoice != nil
        if accepted { acceptedAnswers += 1 }
        var agreed: Bool?
        if let ruleId = item.suggestedId {
            comparedWithRule += 1
            let match = rawChoice == ruleId
            agreed = match
            if match { agreedWithRule += 1 }
        }
        entries.append(JudgeEntry(
            itemIndex: idx, number: num, cls: item.cls, box: item.box,
            ruleSuggestedId: item.suggestedId, judgeChoice: rawChoice,
            accepted: accepted, agreedWithRule: agreed, fromCache: fromCache
        ))
    }

    let rate = comparedWithRule > 0 ? Double(agreedWithRule) / Double(comparedWithRule) : nil
    return JudgeReport(
        mode: "mlx", status: proc.terminationStatus == 0 ? "ok" : "mlx-error-\(proc.terminationStatus)",
        flaggedItemsEvaluated: entries.count, uniqueRequests: orderedKeys.count,
        cacheHits: cacheHits, acceptedAnswers: acceptedAnswers,
        comparedWithRule: comparedWithRule, agreedWithRule: agreedWithRule,
        agreementRate: rate, entries: entries
    )
}

#if canImport(FoundationModels) && compiler(>=6.4)
import FoundationModels

@available(macOS 27.0, *)
@Generable
struct JudgeVerdict {
    var choice: String
}

func runJudge(
    image: CGImage,
    items: [Item],
    legend: [LegendEntry],
    gapIdsByClass: [String: [String]],
    mode: String,
    outDir: URL
) async -> JudgeReport {
    if mode == "mlx" {
        return runMlxJudge(image: image, items: items, gapIdsByClass: gapIdsByClass, outDir: outDir)
    }
    guard mode == "fm" else {
        return JudgeReport(
            mode: mode, status: "disabled", flaggedItemsEvaluated: 0, uniqueRequests: 0,
            cacheHits: 0, acceptedAnswers: 0, comparedWithRule: 0, agreedWithRule: 0,
            agreementRate: nil, entries: []
        )
    }
    guard #available(macOS 27.0, *) else {
        return JudgeReport(
            mode: mode, status: "requires-macos-27", flaggedItemsEvaluated: 0, uniqueRequests: 0,
            cacheHits: 0, acceptedAnswers: 0, comparedWithRule: 0, agreedWithRule: 0,
            agreementRate: nil, entries: []
        )
    }
    let model = SystemLanguageModel.default
    guard model.availability == .available,
          model.capabilities.contains(.vision),
          model.capabilities.contains(.guidedGeneration)
    else {
        return JudgeReport(
            mode: mode, status: "model-unavailable-\(model.availability)", flaggedItemsEvaluated: 0,
            uniqueRequests: 0, cacheHits: 0, acceptedAnswers: 0, comparedWithRule: 0,
            agreedWithRule: 0, agreementRate: nil, entries: []
        )
    }

    let legendNames = Array(Set(legend.map(\.label))).sorted()
    let allGapIds = Array(Set(gapIdsByClass.values.flatMap { $0 })).sorted()
    var cache: [String: String?] = [:]
    var entries: [JudgeEntry] = []
    var uniqueRequests = 0
    var cacheHits = 0
    var acceptedAnswers = 0
    var comparedWithRule = 0
    var agreedWithRule = 0
    var number = 0

    for idx in items.indices where items[idx].needsReview {
        number += 1
        let item = items[idx]
        let classGaps = gapIdsByClass[item.cls] ?? []
        let usingGapSet = !classGaps.isEmpty
        let isObjectGroup = !usingGapSet && (item.reason ?? "").hasPrefix("label this group once (")
        let candidateList: [String]
        if usingGapSet {
            candidateList = allGapIds.count >= 2 ? allGapIds : Array(Set(allGapIds + legendNames)).sorted()
        } else if item.cls == "object" {
            candidateList = structuralGroupLabels
        } else {
            candidateList = legendNames
        }
        guard !candidateList.isEmpty, let (rawBytes, baseCrop) = makeJudgeCrop(image, item: item) else {
            continue
        }
        let candidateSet = Set(candidateList)

        // Cache by group reason for grouped objects, or by raw crop bytes before drawing the number banner.
        let cacheKey: String
        if isObjectGroup, let reason = item.reason {
            cacheKey = "group:\(reason)"
        } else {
            var hasher = SHA256()
            hasher.update(data: rawBytes)
            hasher.update(data: Data(candidateList.joined(separator: "\u{1F}").utf8))
            cacheKey = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        let rawChoice: String?
        let fromCache: Bool
        if let cached = cache[cacheKey] {
            rawChoice = cached
            fromCache = true
            cacheHits += 1
        } else {
            fromCache = false
            uniqueRequests += 1
            let numbered = badgeCrop(baseCrop, number: number)
            let schema = GenerationSchema(
                type: JudgeVerdict.self,
                description: "Closed-set label for a flagged floor plan crop",
                properties: [
                    GenerationSchema.Property(
                        name: "choice",
                        description: "Selected label from the allowed candidates",
                        type: String.self,
                        guides: [.anyOf(candidateList)]
                    )
                ]
            )
            let instructions = usingGapSet
                ? "Read the booth identifier printed inside the crop and return the matching ID from the allowed candidates."
                : "Classify the floor plan crop into the best matching label from the allowed candidates."
            let promptText = "Crop #\(number) (current class: \(item.cls)). Allowed choices: \(candidateList.joined(separator: ", "))."
            let session = LanguageModelSession(model: model, instructions: instructions)
            var picked: String?
            if let response = try? await session.respond(
                schema: schema,
                options: GenerationOptions(samplingMode: .greedy),
                prompt: {
                    Attachment(numbered).label("crop-\(number)")
                    promptText
                }
            ), let parsed = try? JudgeVerdict(response.content), candidateSet.contains(parsed.choice) {
                picked = parsed.choice
            }
            cache[cacheKey] = picked
            rawChoice = picked
        }

        let accepted = rawChoice != nil
        if accepted { acceptedAnswers += 1 }
        var agreed: Bool?
        if let ruleId = item.suggestedId {
            comparedWithRule += 1
            let match = rawChoice == ruleId
            agreed = match
            if match { agreedWithRule += 1 }
        }
        entries.append(JudgeEntry(
            itemIndex: idx, number: number, cls: item.cls, box: item.box,
            ruleSuggestedId: item.suggestedId, judgeChoice: rawChoice,
            accepted: accepted, agreedWithRule: agreed, fromCache: fromCache
        ))
    }

    let rate = comparedWithRule > 0 ? Double(agreedWithRule) / Double(comparedWithRule) : nil
    return JudgeReport(
        mode: mode, status: "ok", flaggedItemsEvaluated: entries.count,
        uniqueRequests: uniqueRequests, cacheHits: cacheHits,
        acceptedAnswers: acceptedAnswers, comparedWithRule: comparedWithRule,
        agreedWithRule: agreedWithRule, agreementRate: rate, entries: entries
    )
}
#else
func runJudge(
    image: CGImage,
    items: [Item],
    legend: [LegendEntry],
    gapIdsByClass: [String: [String]],
    mode: String,
    outDir: URL
) async -> JudgeReport {
    if mode == "mlx" {
        return runMlxJudge(image: image, items: items, gapIdsByClass: gapIdsByClass, outDir: outDir)
    }
    return JudgeReport(
        mode: mode, status: mode == "off" ? "disabled" : "unavailable-at-compile-time",
        flaggedItemsEvaluated: 0, uniqueRequests: 0, cacheHits: 0,
        acceptedAnswers: 0, comparedWithRule: 0, agreedWithRule: 0,
        agreementRate: nil, entries: []
    )
}
#endif
