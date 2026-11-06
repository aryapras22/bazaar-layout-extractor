"""Extract the 43 symbol legend classes from the reference PDFs into images and legends.json.

Reads the four symbol legend PDFs in BazaarSimulator/Core/Resources/Legends,
extracts high-resolution symbol thumbnails, removes tinted page ground,
and writes legends.json and 43 PNGs to Core/Resources/Legends/symbols/.
"""
import argparse
import io
import json
from pathlib import Path

import numpy as np
from PIL import Image
import pymupdf

LEGEND_FILES = [
    ("legend-walls.pdf", "wall"),
    ("legend-doors.pdf", "door"),
    ("legend-tables-seating.pdf", "seat"),
    ("legend-misc.pdf", "misc"),
]

TINT_COLORS = [
    np.array([210, 255, 248]),  # cyan
    np.array([255, 244, 209]),  # beige
    np.array([233, 224, 255]),  # lavender
]

CLASS_IDS = {
    "Wall, double line": "wall.double",
    "Wall, thin line": "wall.thin",
    "Wall, thick line": "wall.thick",
    "Wall, medium line": "wall.medium",
    "Single door, quarter arc": "door.single_quarter",
    "Single door, quarter arc, double wall": "door.single_quarter_double_wall",
    "Single door, half disc": "door.single_half_disc",
    "Double door, two arcs": "door.double_two_arcs",
    "Double door, arcs in thin wall": "door.double_thin_wall",
    "Gate, butterfly": "gate.butterfly",
    "Gate, butterfly with frame": "gate.butterfly_frame",
    "Door row, scalloped": "door.row_scalloped",
    "Door, bow-tie": "door.bow_tie",
    "Table, outline": "table.outline",
    "Table, outline, compact": "table.outline_compact",
    "Table, blue filled": "table.blue_filled",
    "Table, red outline": "table.red_outline",
    "Theater chairs, circles": "seats.theater_circles",
    "Theater chairs, blue squares": "seats.theater_squares",
    "Column, hollow square": "column.hollow_square",
    "Column, solid square": "column.solid_square",
    "Column, solid square, on wall": "column.solid_square_on_wall",
    "Column, hollow circle": "column.hollow_circle",
    "Stairs, ladder": "stairs.ladder",
    "Stairs or escalator, boxed": "stairs.boxed",
    "Restroom, black circle": "restroom.black_circle",
    "Restroom, framed figures": "restroom.framed",
    "Fire point": "safety.fire_point",
    "Emergency exit, right": "safety.emergency_exit_right",
    "Emergency exit, left": "safety.emergency_exit_left",
    "Assembly point": "safety.assembly_point",
    "Ambulance": "safety.ambulance",
    "Info desk icon": "info.desk",
    "Entry arrow": "arrow.entry",
    "Exit arrow": "arrow.exit",
    "Circulation arrow": "arrow.circulation",
    "Stage, grey": "zone.stage_grey",
    "Stage, red": "zone.stage_red",
    "Stage, dark grey": "zone.stage_dark_grey",
    "Neighboring unit": "zone.neighboring_unit",
    "Unlabeled block": "zone.unlabeled_block",
    "Standing zone": "zone.standing",
    "Service room": "zone.service_room",
}

DISTINGUISHED_COLORS = {
    "table.blue_filled": [110, 165, 221],
    "table.red_outline": [233, 136, 132],
    "seats.theater_squares": [110, 163, 217],
    "zone.stage_grey": [170, 170, 170],
    "zone.stage_red": [184, 92, 92],
    "zone.stage_dark_grey": [62, 62, 62],
    "zone.neighboring_unit": [233, 224, 255],
    "zone.unlabeled_block": [190, 29, 45],
    "zone.standing": [190, 191, 190],
    "zone.service_room": [248, 196, 153],
}


def drop_tint(arr: np.ndarray) -> np.ndarray:
    res = arr.copy()
    for tint in TINT_COLORS:
        diff = np.abs(res.astype(int) - tint)
        dist = np.max(diff, axis=-1)
        res[dist <= 25] = [255, 255, 255]
    return res


def extract_symbol_library(legends_dir: Path, out_dir: Path) -> list[dict]:
    out_dir.mkdir(parents=True, exist_ok=True)
    entries = []

    for file_name, layer in LEGEND_FILES:
        pdf_path = legends_dir / file_name
        doc = pymupdf.open(str(pdf_path))

        for page in doc:
            images = page.get_image_info(xrefs=True)
            blocks = [b for b in page.get_text("blocks") if b[1] > 200]
            blocks.sort(key=lambda b: b[1])

            drawings = [
                d
                for d in page.get_drawings()
                if d.get("fill") is not None and 80 <= d["rect"].x0 <= 220
            ]
            drawings.sort(key=lambda d: d["rect"].y0)

            drawing_idx = 0
            for idx, block in enumerate(blocks):
                name = block[4].strip().replace("\n", " ")
                symbol_id = CLASS_IDS.get(name)
                if not symbol_id:
                    raise ValueError(f"Unknown class name: {name}")

                png_name = f"{symbol_id}.png"
                out_png_path = out_dir / png_name

                if idx < len(images):
                    base_img = doc.extract_image(images[idx]["xref"])
                    pil_img = Image.open(io.BytesIO(base_img["image"])).convert("RGB")
                    arr = clean_image_array(drop_tint(np.array(pil_img)), name)
                    Image.fromarray(arr).save(out_png_path)
                else:
                    d = drawings[drawing_idx]
                    drawing_idx += 1
                    fill = [int(round(c * 255)) for c in d["fill"]]
                    arr = np.full((100, 100, 3), fill, dtype=np.uint8)
                    Image.fromarray(arr).save(out_png_path)

                color = DISTINGUISHED_COLORS.get(symbol_id, [0, 0, 0])
                entries.append(
                    {
                        "id": symbol_id,
                        "name": name,
                        "layer": layer,
                        "file": png_name,
                        "color": color,
                    }
                )

    legends_json_path = out_dir / "legends.json"
    with open(legends_json_path, "w", encoding="utf-8") as f:
        json.dump(entries, f, indent=2)

    return entries


def clean_image_array(arr: np.ndarray, name: str) -> np.ndarray:
    if name == "Door row, scalloped":
        arr[arr < 30] = 255
    return arr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--legends-dir",
        type=Path,
        default=Path("BazaarSimulator/Core/Resources/Legends"),
        help="Path to directory containing legend PDFs",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("BazaarSimulator/Core/Resources/Legends/symbols"),
        help="Output directory for legends.json and cropped PNGs",
    )
    args = parser.parse_args()

    entries = extract_symbol_library(args.legends_dir, args.out_dir)
    print(f"Extracted {len(entries)} symbol classes into {args.out_dir}")


if __name__ == "__main__":
    main()
