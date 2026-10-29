import CoreGraphics
import Foundation

// A local vision model reads the tiles the text recogniser could not. It reads crops well and cannot find
// boxes, so it only ever answers for a tile already found, and its answer becomes a suggestion that must fill
// a gap in the class's numbering.

/// Reads an answer such as "GD 29" or "CO26" as the class prefix plus its number, and keeps it only when that
/// ID is one the class is missing and no other tile claims it. The model often gets the letters slightly wrong
/// (CO for GD) and the number right, so the letters come from the class.
func acceptModelIds(
    _ answers: [Int: String], items: [Item], classPrefixes: [String: String], gapIdsByClass: [String: [String]]
) -> [Int: String] {
    let suggested = Set(items.compactMap(\.suggestedId))
    var claims: [String: [Int]] = [:]
    for (idx, raw) in answers {
        let cleaned = String(foldLookalikes(raw.uppercased()).filter { $0.isLetter || $0.isNumber })
        guard let parsed = parseStrictId(cleaned), let prefix = classPrefixes[items[idx].cls] else { continue }
        let candidate = "\(prefix)\(parsed.number)"
        guard gapIdsByClass[items[idx].cls]?.contains(candidate) == true, !suggested.contains(candidate) else { continue }
        claims[candidate, default: []].append(idx)
    }
    var accepted: [Int: String] = [:]
    for (id, claimants) in claims where claimants.count == 1 { accepted[claimants[0]] = id }
    return accepted
}

private func modelCrop(_ image: CGImage, _ item: Item, scale: Int = 4, pad: Int = 12) -> CGImage? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let tile = image.cropping(to: item.rect.intersection(bounds)),
          let ctx = CGContext(
              data: nil, width: (tile.width + 2 * pad) * scale, height: (tile.height + 2 * pad) * scale,
              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    ctx.interpolationQuality = .high
    ctx.draw(tile, in: CGRect(x: pad * scale, y: pad * scale, width: tile.width * scale, height: tile.height * scale))
    return ctx.makeImage()
}

private let readerScript = """
import json, os, re, sys
os.environ["HF_HUB_OFFLINE"] = "1"
from mlx_vlm import load, generate
from mlx_vlm.prompt_utils import apply_chat_template
from mlx_vlm.utils import load_config
model_id = "mlx-community/Qwen3.5-9B-MLX-4bit"
config = load_config(model_id)
model, proc = load(model_id)
prompt = (
    "This is one booth tile cut from a floor plan. Read the booth identifier printed in it: "
    "one or two letters, then a number of one to three digits, possibly on two lines. "
    'Return ONLY JSON: {"id":"<ID>"}'
)
fmt = apply_chat_template(proc, config, prompt, num_images=1, enable_thinking=False)
out = {}
for t in json.load(open(sys.argv[1])):
    res = generate(model, proc, fmt, image=[t["path"]], temperature=0.0, max_tokens=32, verbose=False)
    m = re.search(r'"id"\\s*:\\s*"([^"]*)"', res.text)
    if m:
        out[t["key"]] = m.group(1)
json.dump(out, open(sys.argv[2], "w"))
"""

/// Asks the local model for the ID of every tile in a numbered class that still has none, and records the
/// answers that fit as `suggested_id`. Returns how many it recorded. Only one model process may run at a time
/// on the machine, so it waits for /tmp/fp-vlm.lock.
func readMissingIdsWithModel(
    image: CGImage, items: inout [Item], classPrefixes: [String: String], gapIdsByClass: [String: [String]],
    outDir: URL, ruleCounts: inout [String: Int]
) -> Int {
    let python = NSHomeDirectory() + "/miniconda3/envs/floor-plan-vlm-bench/bin/python"
    guard FileManager.default.isExecutableFile(atPath: python) else {
        FileHandle.standardError.write(Data("note: the model environment is missing, tiles without an ID stay unread\n".utf8))
        return 0
    }
    let asked = items.indices.filter { idx in
        guard let prefix = classPrefixes[items[idx].cls], items[idx].suggestedId == nil, items[idx].shortSide >= 20 else { return false }
        return parseStrictId(items[idx].id)?.prefix != prefix
    }
    guard !asked.isEmpty else { return 0 }

    let dir = outDir.appendingPathComponent("model_crops")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var tasks: [[String: String]] = []
    for idx in asked {
        guard let crop = modelCrop(image, items[idx]) else { continue }
        let path = dir.appendingPathComponent("tile_\(idx).png")
        savePNG(crop, to: path)
        tasks.append(["key": String(idx), "path": path.path])
    }
    let requests = dir.appendingPathComponent("requests.json"), responses = dir.appendingPathComponent("responses.json")
    guard let data = try? JSONSerialization.data(withJSONObject: tasks), (try? data.write(to: requests)) != nil else { return 0 }
    try? FileManager.default.removeItem(at: responses)

    let lock = "/tmp/fp-vlm.lock"
    while mkdir(lock, 0o755) != 0 { sleep(5) }
    defer { rmdir(lock) }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: python)
    proc.arguments = ["-c", readerScript, requests.path, responses.path]
    proc.standardError = FileHandle.nullDevice
    guard (try? proc.run()) != nil else { return 0 }
    proc.waitUntilExit()

    let raw = (try? Data(contentsOf: responses)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    let answers = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Int(key).map { ($0, value) } })
    let accepted = acceptModelIds(answers, items: items, classPrefixes: classPrefixes, gapIdsByClass: gapIdsByClass)
    for (idx, id) in accepted {
        items[idx].suggestedId = id
        items[idx].fixRule = "model-read"
        items[idx].fixReason = "the local model read \"\(answers[idx] ?? "")\" and that fills a gap in the numbering"
        ruleCounts["model-read", default: 0] += 1
    }
    return accepted.count
}
