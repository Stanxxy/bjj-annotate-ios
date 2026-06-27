#!/usr/bin/env python3
"""
Generate BJJAnnotate app icon (1024x1024, opaque RGB).

Design: bold 17-point COCO skeleton node-graph on a deep indigo→violet gradient.
Nodes: filled circles. Edges: lines between connected keypoints.
No alpha channel (required for iOS App Store).

Output: BJJAnnotate/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""

import math
import os
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    raise SystemExit("ERROR: pip install Pillow")

# ─── Canvas ────────────────────────────────────────────────────────────────────
SIZE = 1024
img = Image.new("RGB", (SIZE, SIZE))
draw = ImageDraw.Draw(img)

# ─── Background: deep indigo → violet gradient (top-left → bottom-right) ──────
for y in range(SIZE):
    t = y / SIZE
    # indigo  (#1e1b4b) → violet (#4c1d95)
    r = int(0x1e + t * (0x4c - 0x1e))
    g = int(0x1b + t * (0x1d - 0x1b))
    b = int(0x4b + t * (0x95 - 0x4b))
    draw.line([(0, y), (SIZE - 1, y)], fill=(r, g, b))

# ─── COCO skeleton: 17 keypoints + standard 17-edge connections ───────────────
#
# Layout: a stylised standing BJJ athlete rendered on the icon.
# Keypoints are in normalized [0, 1] coords; we scale to the canvas with
# a generous margin so the figure fills ~70% of the icon.

MARGIN = 0.12  # fraction of SIZE reserved on each side
SCALE = SIZE * (1 - 2 * MARGIN)
OX = SIZE * MARGIN
OY = SIZE * MARGIN

def pt(nx, ny):
    """Normalized coords → pixel coords."""
    return (int(OX + nx * SCALE), int(OY + ny * SCALE))

# 17-point skeleton (index 1-17) in normalized [0,1] coords.
# Pose: relaxed standing guard posture (slight lean, arms low).
kp = {
    1:  (0.50, 0.06),   # nose
    2:  (0.46, 0.04),   # left_eye
    3:  (0.54, 0.04),   # right_eye
    4:  (0.43, 0.07),   # left_ear
    5:  (0.57, 0.07),   # right_ear
    6:  (0.35, 0.22),   # left_shoulder
    7:  (0.65, 0.22),   # right_shoulder
    8:  (0.28, 0.40),   # left_elbow
    9:  (0.72, 0.40),   # right_elbow
    10: (0.22, 0.56),   # left_wrist
    11: (0.78, 0.56),   # right_wrist
    12: (0.39, 0.54),   # left_hip
    13: (0.61, 0.54),   # right_hip
    14: (0.36, 0.74),   # left_knee
    15: (0.64, 0.74),   # right_knee
    16: (0.34, 0.92),   # left_ankle
    17: (0.66, 0.92),   # right_ankle
}

# Standard COCO 17-edge skeleton connections
EDGES = [
    (1, 2), (1, 3), (2, 4), (3, 5),   # head
    (5, 7), (4, 6),                      # head→shoulders
    (6, 7),                              # shoulder span
    (6, 8), (7, 9),                      # upper arms
    (8, 10), (9, 11),                    # lower arms
    (6, 12), (7, 13),                    # torso sides
    (12, 13),                            # hip span
    (12, 14), (13, 15),                  # upper legs
    (14, 16), (15, 17),                  # lower legs
]

# Colors: left=cyan, right=orange, center=white
SIDE_COLOR = {
    1:  (255, 255, 255),
    2:  (0,   220, 220),
    3:  (255, 180,  40),
    4:  (0,   220, 220),
    5:  (255, 180,  40),
    6:  (0,   220, 220),
    7:  (255, 180,  40),
    8:  (0,   220, 220),
    9:  (255, 180,  40),
    10: (0,   220, 220),
    11: (255, 180,  40),
    12: (0,   220, 220),
    13: (255, 180,  40),
    14: (0,   220, 220),
    15: (255, 180,  40),
    16: (0,   220, 220),
    17: (255, 180,  40),
}

EDGE_W = max(4, SIZE // 90)      # edge stroke width
NODE_R = max(7, SIZE // 55)      # node circle radius
GLOW_R = NODE_R + max(3, SIZE // 130)  # glow halo

EDGE_COLOR = (160, 130, 255, 180)  # soft purple edge

# Draw edges first
for (a, b) in EDGES:
    pa = pt(*kp[a])
    pb = pt(*kp[b])
    draw.line([pa, pb], fill=(180, 150, 255), width=EDGE_W)

# Draw node glow halos
for i in range(1, 18):
    px, py = pt(*kp[i])
    c = SIDE_COLOR[i]
    r0, g0, b0 = c
    glow = (min(255, r0 // 2 + 40), min(255, g0 // 2 + 40), min(255, b0 // 2 + 40))
    draw.ellipse(
        [(px - GLOW_R, py - GLOW_R), (px + GLOW_R, py + GLOW_R)],
        fill=glow
    )

# Draw node circles
for i in range(1, 18):
    px, py = pt(*kp[i])
    c = SIDE_COLOR[i]
    draw.ellipse(
        [(px - NODE_R, py - NODE_R), (px + NODE_R, py + NODE_R)],
        fill=c
    )

# ─── Save ─────────────────────────────────────────────────────────────────────
REPO_ROOT = Path(__file__).parent.parent
ICON_DIR = REPO_ROOT / "BJJAnnotate" / "Assets.xcassets" / "AppIcon.appiconset"
ICON_DIR.mkdir(parents=True, exist_ok=True)

OUT = ICON_DIR / "AppIcon-1024.png"
img.save(str(OUT), "PNG", optimize=False)

file_size_kb = OUT.stat().st_size // 1024
print(f"Icon generated: {OUT}  ({file_size_kb} KB)")
print(f"  Mode: {img.mode}, Size: {img.size}")
assert img.mode == "RGB", "Icon must be opaque RGB (no alpha)"
print("DONE")
