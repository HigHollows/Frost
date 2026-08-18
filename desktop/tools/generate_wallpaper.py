#!/usr/bin/env python3
"""Generates a code-driven fallback FROST wallpaper (hex-facet gradient).

NOTE (2026-08): the wallpaper actually shipped in
desktop/wallpaper/frost-wallpaper.png is now a designer-provided asset
(the crystalline "F" mark — see frost-wallpaper-source.png alongside it
for provenance, same convention as branding/logo/frost-logo-source.png),
not this script's output. This generator is kept as a from-code
fallback/alternate — running it will overwrite frost-wallpaper.png with
its own hex-facet-gradient version:

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
    img = Image.alpha_composite(img, speck_layer)

    # Faint hexagon facet lines — FROST's signature shape motif (see
    # DESKTOP.README.md), used sparingly here as a background texture
    # rather than a bold pattern: a handful of large, low-opacity
    # hexagon outlines scattered off-center, like ice-crystal facets
    # half-visible under frost. Deliberately subtle — this is a
    # wallpaper meant to sit behind icons/dock, not a poster.
    hex_layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    hdraw = ImageDraw.Draw(hex_layer)
    random.seed(11)

    def hexagon_points(cx, cy, size):
        return [
            (cx + size * math.cos(math.radians(60 * i - 30)),
             cy + size * math.sin(math.radians(60 * i - 30)))
            for i in range(6)
        ]

    for _ in range(9):
        cx = random.randint(0, width)
        cy = random.randint(0, height)
        size = random.randint(int(width * 0.05), int(width * 0.14))
        alpha = random.randint(10, 22)
        hdraw.polygon(hexagon_points(cx, cy, size), outline=(120, 200, 230, alpha), width=2)

    img = Image.alpha_composite(img, hex_layer).convert("RGB")

    out = os.path.join(OUT_DIR, "frost-wallpaper.png")
    img.save(out, optimize=True)
    print(f"wrote {out} ({width}x{height}, {os.path.getsize(out) // 1024} KiB)")


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    make_wallpaper()
    print("done.")
