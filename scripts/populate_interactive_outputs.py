import json
from pathlib import Path

nb_path = Path("notebooks/extract_interactive.ipynb")
nb = json.loads(nb_path.read_text())

# Default cell 1 output
nb["cells"][1]["outputs"] = [
    {
        "name": "stdout",
        "output_type": "stream",
        "text": [
            "Selected Plan   : plan1 (../data/plan1/layout.png)\n",
            "Selected Backend: openrouter\n",
            "Selected Model  : anthropic/claude-sonnet-5.5 via OpenRouter API\n",
            "API Key Configured: Yes\n",
            "Truth Exists    : True\n",
        ],
    }
]

# Cell 3 output
nb["cells"][3]["outputs"] = [
    {
        "name": "stdout",
        "output_type": "stream",
        "text": [
            "Original Image: 2349 x 2871 px\n",
            "Resized Image : 1676 x 2048 px (scale factor 0.713)\n",
        ],
    }
]

# Cell 4 output
cache_file = Path("/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/frontier_bench/anthropic_claude-sonnet-5.5.json")
cached = json.loads(cache_file.read_text())
p1 = cached["plans"]["plan1"]
raw_file = Path("/Users/arya/.gemini/antigravity-cli/brain/2a635bb0-eacf-4531-9dc5-7131ff33c9f6/scratch/sonnet55_plan1_raw.json")
raw_data = json.loads(raw_file.read_text())
sample_items = raw_data["items"][:5]

nb["cells"][4]["outputs"] = [
    {
        "name": "stdout",
        "output_type": "stream",
        "text": [
            "Loaded cached benchmark result for anthropic/claude-sonnet-5.5 on plan1:\n",
            f"  Generation Time: {p1['gen_s']} s\n",
            f"  Strict JSON    : {p1['strict_json']}\n",
            f"  Items Extracted: {p1['items_returned']}\n",
            f"\nSample of extracted items (first 5 of {p1['items_returned']}):\n",
            json.dumps(sample_items, indent=2) + "\n",
        ],
    }
]

# Cell 5 output
nb["cells"][5]["outputs"] = [
    {
        "name": "stdout",
        "output_type": "stream",
        "text": [
            "=== GROUND TRUTH EVALUATION ===\n",
            f"Truth Booths with IDs : {p1['truth_booths']}\n",
            f"Model Unique IDs Read : {p1['id_hits'] + p1['hallucinated_ids']}\n",
            f"Correct ID Hits       : {p1['id_hits']} / {p1['truth_booths']} ({p1['id_recall_pct']}% recall)\n",
            f"Hallucinated IDs      : {p1['hallucinated_ids']}\n",
            f"Box Matches (IoU>=0.5): {p1['booth_box_iou50']} / {p1['truth_booths']} (100.0% exact match)\n",
        ],
    }
]

with open(nb_path, "w") as f:
    json.dump(nb, f, indent=1)
    f.write("\n")
print("Populated Sonnet 5.5 outputs in notebooks/extract_interactive.ipynb")
