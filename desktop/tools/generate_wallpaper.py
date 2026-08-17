#!/usr/bin/env python3
"""Generates the default FROST wallpaper — same reproducible-from-code
approach as branding/tools/generate_assets.py. Regenerate anytime:

    python desktop/tools/generate_wallpaper.py

Requires Pillow (`pip install Pillow`).
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "..", "wallpaper")

BG_TOP = (10, 14, 20)      # near-black, slightly cooler than pure #0f1419
BG_BOTTOM = (10, 40, 64)     # deep glacier blue
GLOW = (0, 120, 160)           # dim cyan glow, low-key — a wallpaper, not a logo


def make_wallpaper(width=1920, height=1080):
    img = Image.new("RGB", (width, height), BG_TOP)
    px = img.load()
    for y in range(height):
        t = y / (height - 1)
        r = int(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t)
        g = int(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t)
        b = int(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t)
        for x in range(width):
            px[x, y] = (r, g, b)

    # A few large, very soft glow circles (lower-third, off-center) —
    # subtle enough to sit behind desktop icons/dock without competing.
    glow = Image.new("L", (width, height), 0)
    gdraw = ImageDraw.Draw(glow)
    spots = [
        (int(width * 0.75), int(height * 0.85), int(width * 0.35)),
        (int(width * 0.15), int(height * 0.95), int(width * 0.25)),
    ]
    for cx, cy, radius in spots:
        for r in range(radius, 0, -8):
            alpha = int(40 * (1 - r / radius))
            gdraw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=alpha)
    glow = glow.filter(ImageFilter.GaussianBlur(80))

    glow_color = Image.new("RGB", (width, height), GLOW)
    img = Image.composite(glow_color, img, glow)

    # Faint, wide-spaced snowflake specks — very low opacity, texture
    # more than decoration.
    speck_layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(speck_layer)
    import random
    random.seed(4)
    for _ in range(40):
        x = random.randint(0, width)
        y = random.randint(0, height)
        r = random.randint(1, 2)
        a = random.randint(20, 50)
        sdraw.ellipse([x - r, y - r, x + r, y + r], fill=(240, 250, 255, a))
    img = img.convert("RGBA")
    img = Image.alpha_composite(img, speck_layer).convert("RGB")

    out = os.path.join(OUT_DIR, "frost-wallpaper.png")
    img.save(out, optimize=True)
    print(f"wrote {out} ({width}x{height}, {os.path.getsize(out) // 1024} KiB)")


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    make_wallpaper()
    print("done.")
