import json
from pathlib import Path

BENCH_DIR = Path("/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/full_image_vlm")
FRONTIER_DIR = Path("/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/frontier_bench")

LOCAL_MODELS = [
    "mlx-community/Qwen3.5-4B-MLX-4bit",
    "mlx-community/Qwen3.5-9B-MLX-4bit",
    "mlx-community/Qwen3-VL-8B-Instruct-4bit",
    "mlx-community/InternVL3-8B-MLX-4bit",
    "mlx-community/gemma-4-e4b-it-4bit",
    "mlx-community/gemma-4-12B-it-qat-4bit",
    "mlx-community/gemma-3-27b-it-qat-4bit",
]

FRONTIER_MODELS = [
    "anthropic/claude-sonnet-5.5",
    "qwen/qwen2.5-vl-72b-instruct",
    "google/gemini-2.5-flash",
    "openai/gpt-4o",
]

local_results = {}
for m in LOCAL_MODELS:
    slug = m.replace("/", "_")
    p = BENCH_DIR / f"{slug}.json"
    if p.exists():
        local_results[m] = json.loads(p.read_text())

frontier_results = {}
for m in FRONTIER_MODELS:
    slug = m.replace("/", "_")
    p = FRONTIER_DIR / f"{slug}.json"
    if p.exists():
        frontier_results[m] = json.loads(p.read_text())

# Cell 1 output
out_c1 = [f"Configured {len(LOCAL_MODELS)} local models and {len(FRONTIER_MODELS)} frontier OpenRouter models.\n"]

# Cell 3 output
out_c3 = [f"Loaded {len(local_results)} local MLX runs and {len(frontier_results)} high-resolution frontier runs.\n"]

# Cell 4 output
out_c4 = [
    f"{'Frontier Model':<30} | {'Plan':<6} | {'Time (s)':<8} | {'Tokens Out':<10} | {'Strict':<6} | {'Items':<5} | {'ID Recall':<16} | {'Box IoU>=0.5':<12}\n",
    "-" * 108 + "\n",
]
for m, data in frontier_results.items():
    for p_id, p_info in data["plans"].items():
        if p_info.get("truth_booths"):
            id_recall_str = f"{p_info['id_hits']}/{p_info['truth_booths']} ({p_info['id_recall_pct']}%)"
            box_iou_str = f"{p_info['booth_box_iou50']}/{p_info['truth_booths']}"
        else:
            id_recall_str = "N/A"
            box_iou_str = "N/A"
        out_tokens = str(p_info.get("completion_tokens", "N/A"))
        out_c4.append(
            f"{m:<30} | {p_id:<6} | {p_info['gen_s']:<8.1f} | {out_tokens:<10} | {str(p_info['strict_json']):<6} | {p_info['items_returned']:<5} | {id_recall_str:<16} | {box_iou_str:<12}\n"
        )

# Cell 5 output
out_c5 = [
    "=== HIGH-RESOLUTION BENCHMARK: FRONTIER CLOUD vs. LOCAL MLX (PLANS 1, 2, 3) ===\n\n",
    f"{'Model':<32} | {'Type':<10} | {'Total Gen':<10} | {'Items':<6} | {'Plan 1 ID':<10} | {'Plan 2 ID':<10} | {'Plan 3 ID':<10} | {'Total ID Hits':<16} | {'Total Box IoU50':<16}\n",
    "-" * 135 + "\n",
]

for m, data in frontier_results.items():
    total_gen = sum(p.get("gen_s", 0) for p in data["plans"].values())
    total_items = sum(p.get("items_returned", 0) for p in data["plans"].values())
    p1 = data["plans"].get("plan1", {})
    p2 = data["plans"].get("plan2", {})
    p3 = data["plans"].get("plan3", {})
    p1_id = f"{p1.get('id_hits', 0)}/{p1.get('truth_booths', 153)}"
    p2_id = f"{p2.get('id_hits', 0)}/{p2.get('truth_booths', 209)}"
    p3_id = f"{p3.get('id_hits', 0)}/{p3.get('truth_booths', 67)}"
    tot_hits = sum(p.get("id_hits", 0) for p in data["plans"].values())
    tot_booths = sum(p.get("truth_booths", 0) for p in data["plans"].values())
    tot_box = sum(p.get("booth_box_iou50", 0) for p in data["plans"].values())
    pct = round(100.0 * tot_hits / max(1, tot_booths), 1)
    out_c5.append(
        f"{m:<32} | {'Cloud API':<10} | {total_gen:>7.1f} s  | {total_items:>6} | {p1_id:<10} | {p2_id:<10} | {p3_id:<10} | {tot_hits:>4}/{tot_booths:<4} ({pct:>5.1f}%) | {tot_box:>4}/{tot_booths:<4}\n"
    )

for m, data in local_results.items():
    m_short = m.split("/")[-1]
    p_subset = {pid: p for pid, p in data["plans"].items() if pid in ("plan1", "plan2", "plan3")}
    total_gen = sum(p["gen_s"] for p in p_subset.values())
    total_items = sum(p["items_returned"] for p in p_subset.values())
    p1 = p_subset.get("plan1", {})
    p2 = p_subset.get("plan2", {})
    p3 = p_subset.get("plan3", {})
    p1_id = f"{p1.get('id_hits', 0)}/{p1.get('truth_booths', 153)}"
    p2_id = f"{p2.get('id_hits', 0)}/{p2.get('truth_booths', 209)}"
    p3_id = f"{p3.get('id_hits', 0)}/{p3.get('truth_booths', 67)}"
    tot_hits = sum(p.get("id_hits", 0) for p in p_subset.values())
    tot_booths = sum(p.get("truth_booths", 0) for p in p_subset.values())
    tot_box = sum(p.get("booth_box_iou50", 0) for p in p_subset.values())
    pct = round(100.0 * tot_hits / max(1, tot_booths), 1)
    out_c5.append(
        f"{m_short:<32} | {'Local MLX':<10} | {total_gen:>7.1f} s  | {total_items:>6} | {p1_id:<10} | {p2_id:<10} | {p3_id:<10} | {tot_hits:>4}/{tot_booths:<4} ({pct:>5.1f}%) | {tot_box:>4}/{tot_booths:<4}\n"
    )

nb_path = Path("notebooks/extract_vlm.ipynb")
nb = json.loads(nb_path.read_text())
nb["cells"][1]["outputs"] = [{"name": "stdout", "output_type": "stream", "text": out_c1}]
nb["cells"][3]["outputs"] = [{"name": "stdout", "output_type": "stream", "text": out_c3}]
nb["cells"][4]["outputs"] = [{"name": "stdout", "output_type": "stream", "text": out_c4}]
nb["cells"][5]["outputs"] = [{"name": "stdout", "output_type": "stream", "text": out_c5}]

with open(nb_path, "w") as f:
    json.dump(nb, f, indent=1)
    f.write("\n")
print("Updated notebooks/extract_vlm.ipynb with frontier benchmark outputs.")
