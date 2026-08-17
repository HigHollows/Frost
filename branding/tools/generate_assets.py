#!/usr/bin/env python3
"""Generates the FROST branding image assets: GRUB/Plymouth backgrounds,
the dark-theme logo variants derived from the canonical logo, and the
Plymouth boot-animation frames.

The canonical logo (branding/logo/frost-logo.png) is hand-designed art,
committed as-is — everything else in this file is derived from it or
generated outright, in keeping with FROST's "no unexplained binaries"
principle. Regenerate the derived assets anytime with:

    python branding/tools/generate_assets.py

Requires Pillow (`pip install Pillow`).
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
GRUB_DIR = os.path.join(HERE, "..", "grub")
PLYMOUTH_FRAMES_DIR = os.path.join(HERE, "..", "plymouth", "frames")
PLYMOUTH_DIR = os.path.join(HERE, "..", "plymouth")
LOGO_DIR = os.path.join(HERE, "..", "logo")
# The as-provided file has no real alpha channel (checked: fully opaque) —
# its "transparent" background was flattened into a very-light-gray
# checkerboard (~#F6F6F6/#FEFEFE) instead of true transparency. We rebuild
# a real alpha mask from it (see extract_logo_alpha) rather than use it
# as-is; frost-logo-source.png is kept untouched for provenance.
SOURCE_LOGO = os.path.join(LOGO_DIR, "frost-logo-source.png")
CANONICAL_LOGO = os.path.join(LOGO_DIR, "frost-logo.png")

# Glacier palette
BG_TOP = (5, 8, 12)          # near-black
BG_BOTTOM = (10, 40, 64)      # deep glacier blue
GLOW = (60, 140, 190)          # soft cyan-blue glow behind the logo
ICE = (170, 225, 250)           # bright ice-blue for logo/snow
ICE_DIM = (110, 175, 210)

def make_background(width=1280, height=720):
    img = Image.new("RGB", (width, height), BG_TOP)
    px = img.load()
    for y in range(height):
        t = y / (height - 1)
        r = int(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t)
        g = int(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t)
        b = int(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t)
        for x in range(width):
            px[x, y] = (r, g, b)

    # Soft radial glow centered where the logo/menu will sit.
    glow = Image.new("L", (width, height), 0)
    gdraw = ImageDraw.Draw(glow)
    cx, cy = width // 2, int(height * 0.42)
    max_r = int(width * 0.42)
    for i, r in enumerate(range(max_r, 0, -6)):
        alpha = int(70 * (1 - r / max_r))
        gdraw.ellipse([cx - r, cy - r // 2, cx + r, cy + r // 2], fill=alpha)
    glow = glow.filter(ImageFilter.GaussianBlur(40))

    glow_color = Image.new("RGB", (width, height), GLOW)
    img = Image.composite(glow_color, img, glow)

    out = os.path.join(GRUB_DIR, "background.png")
    img.save(out, optimize=True)
    print(f"wrote {out} ({os.path.getsize(out) // 1024} KiB)")


def extract_logo_alpha(img, ink_below=150, clear_above=232):
    """Rebuilds a real alpha mask from the flattened source: pixels at or
    below `ink_below` brightness are the crystal's black linework (fully
    opaque); pixels at or above `clear_above` are checkerboard/background
    (fully transparent); in between is a smooth ramp for anti-aliased
    edges. This deliberately treats the source's "white" facets as
    background too — they're not reliably distinguishable from the
    checkerboard by brightness alone (both sit in the 240-255 range) — so
    what survives is the crystal's outline + shadow-facet linework as a
    clean silhouette, not the full black/white faceted shading.
    """
    gray = img.convert("L")

    def alpha_fn(v):
        if v <= ink_below:
            return 255
        if v >= clear_above:
            return 0
        return int(255 * (clear_above - v) / (clear_above - ink_below))

    return gray.point(alpha_fn)


def recolor_with_alpha(alpha, size, color):
    solid = Image.new("RGBA", size, color + (255,))
    solid.putalpha(alpha)
    return solid


def make_logo_variants():
    if not os.path.exists(SOURCE_LOGO):
        raise SystemExit(
            f"Source logo not found at {SOURCE_LOGO} — place the designer's "
            "PNG there before running this script."
        )
    source = Image.open(SOURCE_LOGO).convert("RGB")
    alpha = extract_logo_alpha(source)

    # Canonical logo: black linework on a real transparent background —
    # for README / any light-background use.
    canonical = recolor_with_alpha(alpha, source.size, (10, 12, 15))
    canonical.save(CANONICAL_LOGO, optimize=True)
    print(f"wrote {CANONICAL_LOGO} ({canonical.width}x{canonical.height}, {os.path.getsize(CANONICAL_LOGO) // 1024} KiB)")

    # Dark-theme variant: bright ice-blue linework, for GRUB/Plymouth.
    dark = recolor_with_alpha(alpha, source.size, ICE)

    def sized(img, target_h):
        w = int(img.width * (target_h / img.height))
        return img.resize((w, target_h), Image.LANCZOS)

    grub_logo = sized(dark, 260)
    out = os.path.join(GRUB_DIR, "frost-logo.png")
    grub_logo.save(out, optimize=True)
    print(f"wrote {out} ({grub_logo.width}x{grub_logo.height}, {os.path.getsize(out) // 1024} KiB)")

    plymouth_logo = sized(dark, 190)
    out = os.path.join(PLYMOUTH_DIR, "frost-logo.png")
    plymouth_logo.save(out, optimize=True)
    print(f"wrote {out} ({plymouth_logo.width}x{plymouth_logo.height}, {os.path.getsize(out) // 1024} KiB)")

    return grub_logo.size, plymouth_logo.size


def draw_snowflake(draw, cx, cy, radius, growth, width=3, color=ICE):
    """growth in [0,1]: how far the 6 branches have grown out."""
    if growth <= 0:
        return
    r = radius * growth
    for i in range(6):
        angle = math.radians(60 * i - 90)
        ex = cx + r * math.cos(angle)
        ey = cy + r * math.sin(angle)
        draw.line([(cx, cy), (ex, ey)], fill=color, width=width)
        # small side branches near the tip, once mostly grown
        if growth > 0.35:
            branch_t = min(1.0, (growth - 0.35) / 0.65)
            bx = cx + r * 0.6 * math.cos(angle)
            by = cy + r * 0.6 * math.sin(angle)
            blen = radius * 0.28 * branch_t
            for sign in (-1, 1):
                bangle = angle + sign * math.radians(35)
                bex = bx + blen * math.cos(bangle)
                bey = by + blen * math.sin(bangle)
                draw.line([(bx, by), (bex, bey)], fill=color, width=max(1, width - 1))


def make_plymouth_frames(n=8, size=160):
    os.makedirs(PLYMOUTH_FRAMES_DIR, exist_ok=True)
    cx = cy = size // 2
    radius = size * 0.38
    for i in range(1, n + 1):
        growth = i / n
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        # faint outer ring = "ice forming" glow, grows with progress
        ring_alpha = int(60 * growth)
        d.ellipse(
            [cx - radius - 6, cy - radius - 6, cx + radius + 6, cy + radius + 6],
            outline=ICE_DIM + (ring_alpha,),
            width=2,
        )
        draw_snowflake(d, cx, cy, radius, growth, width=4, color=ICE + (255,))
        draw_snowflake(d, cx, cy, radius * 0.55, growth, width=2, color=ICE_DIM + (200,))
        out = os.path.join(PLYMOUTH_FRAMES_DIR, f"frame{i}.png")
        img.save(out, optimize=True)
    print(f"wrote {n} frames to {PLYMOUTH_FRAMES_DIR}")

    # A static "lock" frame (used at the password prompt) — fully-grown
    # snowflake, dimmer, so the animation reads as "paused".
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    draw_snowflake(d, cx, cy, radius, 1.0, width=3, color=ICE_DIM + (180,))
    out = os.path.join(PLYMOUTH_DIR, "lock.png")
    img.save(out, optimize=True)
    print(f"wrote {out}")


def make_plymouth_background(width=1280, height=720):
    # Same palette as GRUB but without the glow — Plymouth draws its own
    # sprite animation on top.
    img = Image.new("RGB", (width, height), BG_TOP)
    px = img.load()
    for y in range(height):
        t = y / (height - 1)
        r = int(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t)
        g = int(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t)
        b = int(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t)
        for x in range(width):
            px[x, y] = (r, g, b)
    out = os.path.join(PLYMOUTH_DIR, "background.png")
    img.save(out, optimize=True)
    print(f"wrote {out} ({os.path.getsize(out) // 1024} KiB)")


if __name__ == "__main__":
    os.makedirs(GRUB_DIR, exist_ok=True)
    os.makedirs(PLYMOUTH_DIR, exist_ok=True)
    make_background()
    grub_size, plymouth_size = make_logo_variants()
    make_plymouth_background()
    make_plymouth_frames()
    print(f"done. GRUB logo: {grub_size}, Plymouth logo: {plymouth_size}")
