import CoreGraphics
import CoreText
import Foundation

/// One question to the model about one extracted item, and its answer once checked.
/// Proposals are written to vlm_fix.json and never applied: the model judges a side-by-side snapshot,
/// and until it is scored against truth.json its edits are suggestions for a person to accept.
struct VlmProposal: Codable {
    var layer: String
    var itemIndex: Int
    var cls: String
    var box: [Int]
    var id: String?
    var trigger: String
    var snapshot: String
    var action: String?
    var value: String?
    var why: String?
    var valid: Bool

    enum CodingKeys: String, CodingKey {
        case layer, itemIndex = "item_index", cls = "class", box, id, trigger, snapshot, action, value, why, valid
    }
}

struct VlmFixReport: Codable {
    var backend: String
    var model: String
    var status: String
    var proposals: [VlmProposal]
}

struct VlmTask {
    var key: String
    var proposal: VlmProposal
    var snapshot: CGImage
    var prompt: String
    var actions: [String]
    /// Values each action accepts; keep and drop take none, and set_id takes a booth ID.
    var values: [String: [String]]
}

private struct VlmAnswer: Codable {
    var action: String
    var value: String
    var why: String
}

func runVlmFix(image: CGImage, items: [Item], classNames: [String], backend: String, outDir: URL) async -> VlmFixReport {
    let dir = outDir.appendingPathComponent("vlm_fix")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tasks = vlmFixBooths(image, items, classNames: classNames, dir: dir)
        + vlmFixWalls(image, items, dir: dir)
        + vlmFixDoors(image, items, dir: dir)
        + vlmFixSeats(image, items, dir: dir)

    let model: String
    let status: String
    let answers: [String: VlmAnswer]
    if backend == "mlx" {
        model = ProcessInfo.processInfo.environment["FP_VLM_MODEL"] ?? "mlx-community/Qwen3.5-9B-MLX-4bit"
        (status, answers) = askMlx(tasks, model: model, dir: dir)
    } else {
        model = "SystemLanguageModel.default"
        (status, answers) = await askFoundationModel(tasks)
    }

    let proposals = tasks.map { task -> VlmProposal in
        var p = task.proposal
        guard let answer = answers[task.key] else { return p }
        p.action = answer.action
        p.value = answer.value
        p.why = answer.why
        p.valid = isValid(answer, for: task)
        return p
    }
    return VlmFixReport(backend: backend, model: model, status: status, proposals: proposals)
}

func vlmFixBooths(_ image: CGImage, _ items: [Item], classNames: [String], dir: URL) -> [VlmTask] {
    vlmTasks(image, items, layer: .booth, dir: dir, about: "booth tiles, each outlined with the ID that was read", actions: [
        "keep": "the outline and ID match the plan",
        "drop": "there is no booth under the red outline",
        "set_id": "the ID printed on the plan differs; value is the ID exactly as printed",
        "set_class": "the booth colour belongs to another legend class; value is one of: \(classNames.joined(separator: ", "))",
    ], values: ["set_class": classNames])
}

func vlmFixWalls(_ image: CGImage, _ items: [Item], dir: URL) -> [VlmTask] {
    vlmTasks(image, items, layer: .wall, dir: dir, about: "walls drawn as lines and pillars drawn as boxes", actions: [
        "keep": "the red item is a real wall or pillar of that kind",
        "drop": "the red item is not structure (text, furniture, a booth edge, a duplicate)",
        "set_class": "the red item is structure of the other kind; value is wall or pillar",
    ], values: ["set_class": ["wall", "pillar"]])
}

func vlmFixDoors(_ image: CGImage, _ items: [Item], dir: URL) -> [VlmTask] {
    vlmTasks(image, items, layer: .door, dir: dir, about: "door swing symbols drawn as boxes", actions: [
        "keep": "the red box holds a door leaf with its quarter or half circle swing arc",
        "drop": "the red box holds something else (a chair, a round table, a box corner, a digit)",
    ], values: [:])
}

func vlmFixSeats(_ image: CGImage, _ items: [Item], dir: URL) -> [VlmTask] {
    vlmTasks(image, items, layer: .seat, dir: dir, about: "furniture drawn as outlines", actions: [
        "keep": "the red item is one piece of furniture and its seat flag is right",
        "drop": "the red item is not furniture (text, a wall piece, noise, a duplicate)",
        "set_seat": "the seat flag is wrong; value is true if people sit on or at it, else false",
    ], values: ["set_seat": ["true", "false"]])
}

/// Items the rules flagged, plus items that mostly cover another item of the same layer.
/// Half the smaller box is the cut so walls meeting at a corner do not count as overlapping.
/// A flagged group of look-alike shapes is asked about once, through its first member, as the judge does.
private func vlmTargets(_ items: [Item], layer: Layer) -> [(index: Int, trigger: String)] {
    let mine = items.indices.filter { Layer.of(items[$0]) == layer }
    var askedGroups = Set<String>()
    return mine.compactMap { i in
        if items[i].needsReview {
            guard let reason = items[i].reason, reason.hasPrefix("label this group once (") else { return (i, "review") }
            return askedGroups.insert(reason).inserted ? (i, "review") : nil
        }
        let overlaps = mine.contains { $0 != i && !isChairInGroup(items[i], items[$0]) && overlapShare(items[i].rect, items[$0].rect) > 0.5 }
        return overlaps ? (i, "overlap") : nil
    }
}

/// The seat layer keeps each chair as its own item and also counts it inside its chair group, so that pair overlaps by design.
private func isChairInGroup(_ a: Item, _ b: Item) -> Bool {
    Set([a.kind, b.kind]) == Set(["chair", "chair_group"])
}

private func overlapShare(_ a: CGRect, _ b: CGRect) -> Double {
    let cut = a.intersection(b)
    guard !cut.isNull else { return 0 }
    return Double(cut.width * cut.height) / max(1, Double(min(a.width * a.height, b.width * b.height)))
}

private func vlmTasks(
    _ image: CGImage, _ items: [Item], layer: Layer, dir: URL, about: String,
    actions: [String: String], values: [String: [String]]
) -> [VlmTask] {
    let order = ["keep", "drop", "set_id", "set_class", "set_seat"].filter { actions[$0] != nil }
    return vlmTargets(items, layer: layer).compactMap { target in
        let item = items[target.index]
        guard let snapshot = vlmSnapshot(image, items: items, layer: layer, target: target.index) else { return nil }
        let key = "\(layer.rawValue)_\(target.index)"
        let url = dir.appendingPathComponent("\(key).png")
        savePNG(snapshot, to: url)
        let prompt = """
        The left half is a crop of the original floor plan. The right half draws the extracted \(about) for the same \
        area, on white. The item in question is red in both halves; other extracted items are blue. It was sent for \
        checking because \(target.trigger == "review" ? "the rules were unsure about it" : "it overlaps another item").
        Item: \(itemSummary(item))
        Compare the drawing with the plan and pick one action:
        \(order.map { "- \($0): \(actions[$0]!)" }.joined(separator: "\n"))
        Return ONLY valid JSON: {"action": "<action>", "value": "<value or empty>", "why": "<one short sentence>"}
        """
        let proposal = VlmProposal(
            layer: layer.rawValue, itemIndex: target.index, cls: item.cls, box: item.box, id: item.id,
            trigger: target.trigger, snapshot: url.path, action: nil, value: nil, why: nil, valid: false)
        return VlmTask(key: key, proposal: proposal, snapshot: snapshot, prompt: prompt, actions: order, values: values)
    }
}

/// Polygons are left out: they are long, and the drawing already shows the shape.
private func itemSummary(_ item: Item) -> String {
    var fields: [String: Any] = ["class": item.cls, "box": item.box, "id": item.id ?? NSNull()]
    if let reason = item.reason { fields["reason"] = reason }
    if let seat = item.seat { fields["seat"] = seat }
    if let kind = item.kind { fields["kind"] = kind }
    if let chairs = item.chairs { fields["chairs"] = chairs }
    if let segment = item.segment { fields["segment"] = segment }
    let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private func isValid(_ answer: VlmAnswer, for task: VlmTask) -> Bool {
    guard task.actions.contains(answer.action) else { return false }
    if answer.action == "keep" || answer.action == "drop" { return true }
    if let allowed = task.values[answer.action] { return allowed.contains(answer.value) }
    return answer.value.range(of: #"^[A-Z0-9][A-Z0-9-]{0,7}$"#, options: .regularExpression) != nil
}

/// Original plan on the left, the layer's JSON drawn on white on the right, both over the same region.
private func vlmSnapshot(_ image: CGImage, items: [Item], layer: Layer, target: Int) -> CGImage? {
    let box = items[target].rect
    let pad = max(40, box.width, box.height)
    let region = box.insetBy(dx: -pad, dy: -pad)
        .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
    guard region.width >= 1, region.height >= 1, let crop = image.cropping(to: region) else { return nil }

    let side = 384.0
    let gap = 8.0
    guard let ctx = CGContext(
        data: nil, width: Int(2 * side + gap), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 2 * side + gap, height: side))
    ctx.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: side, y: 0, width: gap, height: side))

    let s = min(side / region.width, side / region.height)
    let shownHeight = region.height * s
    // Plan coordinates have a top-left origin; the context's origin is bottom-left.
    func point(_ x: Double, _ y: Double, panel: Int) -> CGPoint {
        CGPoint(x: Double(panel) * (side + gap) + (x - region.minX) * s, y: side - (y - region.minY) * s)
    }
    func rect(_ r: CGRect, panel: Int) -> CGRect {
        let a = point(r.minX, r.maxY, panel: panel)
        return CGRect(x: a.x, y: a.y, width: r.width * s, height: r.height * s)
    }
    let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    let blue = CGColor(red: 0, green: 0.3, blue: 1, alpha: 1)

    ctx.interpolationQuality = .high
    ctx.draw(crop, in: CGRect(x: 0, y: side - shownHeight, width: region.width * s, height: shownHeight))
    ctx.setStrokeColor(red)
    ctx.setLineWidth(2)
    ctx.stroke(rect(box, panel: 0))

    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 11, nil)
    ctx.saveGState()
    ctx.clip(to: CGRect(x: side + gap, y: 0, width: side, height: side))
    for (index, item) in items.enumerated() where Layer.of(item) == layer && item.rect.intersects(region) {
        let color = index == target ? red : blue
        ctx.setStrokeColor(color)
        ctx.setLineWidth(index == target ? 2.5 : 1.5)
        if let seg = item.segment {
            ctx.move(to: point(Double(seg[0]), Double(seg[1]), panel: 1))
            ctx.addLine(to: point(Double(seg[2]), Double(seg[3]), panel: 1))
            ctx.strokePath()
        } else if let poly = item.polygon, poly.count >= 3 {
            ctx.addLines(between: poly.map { point(Double($0[0]), Double($0[1]), panel: 1) })
            ctx.closePath()
            ctx.strokePath()
        } else {
            ctx.stroke(rect(item.rect, panel: 1))
        }
        guard let id = item.id else { continue }
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: id, attributes: attrs))
        let c = point(item.centerX, item.centerY, panel: 1)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: c.x - width / 2, y: c.y - 4)
        CTLineDraw(line, ctx)
    }
    ctx.restoreGState()
    return ctx.makeImage()
}

private func askMlx(_ tasks: [VlmTask], model: String, dir: URL) -> (String, [String: VlmAnswer]) {
    let pythonPath = NSHomeDirectory() + "/miniconda3/envs/floor-plan-vlm-bench/bin/python"
    guard !tasks.isEmpty else { return ("ok", [:]) }
    guard FileManager.default.isExecutableFile(atPath: pythonPath) else { return ("missing-env-floor-plan-vlm-bench", [:]) }
    let requestURL = dir.appendingPathComponent("requests.json")
    let answerURL = dir.appendingPathComponent("answers.json")
    let request = tasks.map { ["key": $0.key, "image": $0.proposal.snapshot, "prompt": $0.prompt] }
    guard let body = try? JSONSerialization.data(withJSONObject: request), (try? body.write(to: requestURL)) != nil else {
        return ("write-requests-failed", [:])
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: pythonPath)
    proc.arguments = ["-c", vlmFixScript, model, requestURL.path, answerURL.path]
    try? proc.run()
    proc.waitUntilExit()
    let answers = (try? Data(contentsOf: answerURL)).flatMap { try? JSONDecoder().decode([String: VlmAnswer].self, from: $0) } ?? [:]
    return (proc.terminationStatus == 0 ? "ok" : "mlx-error-\(proc.terminationStatus)", answers)
}

private let vlmFixScript = #"""
import json, os, re, sys
os.environ["HF_HUB_OFFLINE"] = "1"
from mlx_vlm import load, generate
from mlx_vlm.prompt_utils import apply_chat_template
from mlx_vlm.utils import load_config

model_id = sys.argv[1]
config = load_config(model_id)
model, proc = load(model_id)
out = {}
for r in json.load(open(sys.argv[2])):
    fmt = apply_chat_template(proc, config, r["prompt"], num_images=1, enable_thinking=False)
    res = generate(model, proc, fmt, image=[r["image"]], temperature=0.0, max_tokens=96, verbose=False)
    text = re.sub(r"<think>.*?</think>", "", res.text, flags=re.DOTALL)
    m = re.search(r"\{.*?\}", text, flags=re.DOTALL)
    try:
        a = json.loads(m.group(0)) if m else None
    except ValueError:
        a = None
    if isinstance(a, dict) and "action" in a:
        out[r["key"]] = {"action": str(a["action"]), "value": str(a.get("value") or ""), "why": str(a.get("why") or "")}
json.dump(out, open(sys.argv[3], "w"))
"""#

#if canImport(FoundationModels) && compiler(>=6.4)
import FoundationModels

@available(macOS 27.0, *)
@Generable
struct VlmVerdict {
    var action: String
    var value: String
    var why: String
}

private func askFoundationModel(_ tasks: [VlmTask]) async -> (String, [String: VlmAnswer]) {
    guard #available(macOS 27.0, *) else { return ("requires-macos-27", [:]) }
    let model = SystemLanguageModel.default
    guard model.availability == .available,
          model.capabilities.contains(.vision),
          model.capabilities.contains(.guidedGeneration)
    else { return ("model-unavailable-\(model.availability)", [:]) }

    var answers: [String: VlmAnswer] = [:]
    for task in tasks {
        let schema = GenerationSchema(
            type: VlmVerdict.self,
            description: "A check of one extracted floor plan item against the plan",
            properties: [
                GenerationSchema.Property(name: "action", description: "The chosen action", type: String.self, guides: [.anyOf(task.actions)]),
                GenerationSchema.Property(name: "value", description: "The action's value, or empty", type: String.self, guides: []),
                GenerationSchema.Property(name: "why", description: "One short sentence", type: String.self, guides: []),
            ]
        )
        let session = LanguageModelSession(model: model, instructions: "You check extracted floor plan data against the drawing it came from.")
        if let response = try? await session.respond(
            schema: schema,
            options: GenerationOptions(samplingMode: .greedy),
            prompt: {
                Attachment(task.snapshot).label(task.key)
                task.prompt
            }
        ), let verdict = try? VlmVerdict(response.content) {
            answers[task.key] = VlmAnswer(action: verdict.action, value: verdict.value, why: verdict.why)
        }
    }
    return ("ok", answers)
}
#else
private func askFoundationModel(_ tasks: [VlmTask]) async -> (String, [String: VlmAnswer]) {
    ("unavailable-at-compile-time", [:])
}
#endif
