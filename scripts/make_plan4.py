"""Cut data/plan4/layout.png and legend.png out of the scanned page data/plan4/source.png.

The page is rotated 90 degrees. Rotate it upright, crop the plan and the legend box, and
upscale 3x so the plan is about 2,640 px wide, close to the other plans. Run from the project root.
"""
import cv2

SCALE = 3
PLAN_BOX = (60, 415, 940, 750)  # x0, y0, x1, y1 in the upright page
LEGEND_BOX = (1022, 585, 1366, 925)

page = cv2.rotate(cv2.imread("data/plan4/source.png"), cv2.ROTATE_90_CLOCKWISE)
for name, (x0, y0, x1, y1) in [("layout", PLAN_BOX), ("legend", LEGEND_BOX)]:
    crop = page[y0:y1, x0:x1]
    big = cv2.resize(crop, None, fx=SCALE, fy=SCALE, interpolation=cv2.INTER_CUBIC)
    cv2.imwrite(f"data/plan4/{name}.png", big)
    print(name, big.shape[1], "x", big.shape[0])
