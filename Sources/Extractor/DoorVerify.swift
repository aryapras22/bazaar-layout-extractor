import Foundation

/// Optional second opinion on swing symbols. A local VLM looks at each candidate crop and says whether it is
/// a door swing. It only removes candidates: models classify crops well but place boxes badly, so it
/// never finds or moves a box. On plans 1 to 6 it removed 15 of 27 false candidates and 4 of 36 real ones.
func dropUnconfirmedDoors(_ items: inout [Item], planPath: String, outDir: URL) {
    let pythonPath = NSHomeDirectory() + "/miniconda3/envs/floor-plan-vlm-bench/bin/python"
    let candidates = items.indices.filter { items[$0].cls == "door" && (items[$0].reason ?? "").hasPrefix("swing symbol") }
    guard !candidates.isEmpty else { return }
    guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
        FileHandle.standardError.write(Data("warning: --verify-doors needs the floor-plan-vlm-bench env, keeping every swing\n".utf8))
        return
    }
    let requestURL = outDir.appendingPathComponent("door_verify_request.json")
    let answerURL = outDir.appendingPathComponent("door_verify_answer.json")
    let request: [[String: Any]] = candidates.map { ["key": $0, "box": items[$0].box] }
    guard let body = try? JSONSerialization.data(withJSONObject: request) else { return }
    try? body.write(to: requestURL)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: pythonPath)
    proc.arguments = ["-c", doorVerifyScript, planPath, requestURL.path, answerURL.path]
    try? proc.run()
    proc.waitUntilExit()

    guard let data = try? Data(contentsOf: answerURL),
          let answers = try? JSONDecoder().decode([String: Bool].self, from: data) else {
        FileHandle.standardError.write(Data("warning: door verification gave no answers, keeping every swing\n".utf8))
        return
    }
    let rejected = Set(candidates.filter { answers[String($0)] == false })
    items = items.indices.filter { !rejected.contains($0) }.map { items[$0] }
}

private let doorVerifyScript = #"""
import json, os, re, sys
os.environ["HF_HUB_OFFLINE"] = "1"
import numpy as np
from PIL import Image
from mlx_vlm import load, generate
from mlx_vlm.prompt_utils import apply_chat_template
from mlx_vlm.utils import load_config

MODEL = "mlx-community/Qwen3.5-9B-MLX-4bit"
plan = Image.open(sys.argv[1]).convert("RGB")
requests = json.load(open(sys.argv[2]))

def panel(box, pad, mark):
    x, y, w, h = box
    x0, y0 = max(0, x - pad), max(0, y - pad)
    crop = np.array(plan.crop((x0, y0, x + w + pad, y + h + pad)))
    if mark:
        crop[y - y0, max(0, x - x0):x - x0 + w + 1] = (255, 0, 0)
        crop[min(crop.shape[0] - 1, y - y0 + h), max(0, x - x0):x - x0 + w + 1] = (255, 0, 0)
        crop[max(0, y - y0):y - y0 + h + 1, x - x0] = (255, 0, 0)
        crop[max(0, y - y0):y - y0 + h + 1, min(crop.shape[1] - 1, x - x0 + w)] = (255, 0, 0)
    side = 320
    scale = side / max(crop.shape[:2])
    img = Image.fromarray(crop).resize((max(1, round(crop.shape[1] * scale)), max(1, round(crop.shape[0] * scale))), Image.BICUBIC)
    canvas = Image.new("RGB", (side, side), (255, 255, 255))
    canvas.paste(img, (0, 0))
    return canvas

config = load_config(MODEL)
model, processor = load(MODEL)
prompt = (
    "Each image shows a floor plan symbol. The left half is a close-up and the right half is the surrounding "
    "context with a red box around the symbol. Is the red-boxed symbol a door swing symbol, meaning a door leaf "
    "(a straight line) together with a quarter-circle or half-circle arc that shows how the door opens? "
    "A double door is drawn as two mirrored half-discs or arcs meeting in a bow tie shape, and also counts. "
    "Table chairs, round tables, corners of boxes, text digits and bare walls are not door swings. "
    'Return ONLY valid JSON: {"door": true} or {"door": false}'
)
formatted = apply_chat_template(processor, config, prompt, num_images=1, enable_thinking=False)
answers = {}
tmp = sys.argv[3] + ".png"
for r in requests:
    box = r["box"]
    sheet = Image.new("RGB", (640, 320))
    sheet.paste(panel(box, max(4, int(0.15 * max(box[2], box[3]))), False), (0, 0))
    sheet.paste(panel(box, int(1.5 * max(box[2], box[3])) + 10, True), (320, 0))
    sheet.save(tmp)
    res = generate(model, processor, formatted, image=[tmp], temperature=0.0, max_tokens=24, verbose=False)
    text = re.sub(r"<think>.*?</think>", "", res.text, flags=re.DOTALL).lower()
    answers[str(r["key"])] = bool(re.search(r'"door"\s*:\s*true', text))
json.dump(answers, open(sys.argv[3], "w"))
"""#
