#!/usr/bin/env python3
"""Generates the FROST branding image assets: GRUB background + logo,
and the Plymouth boot-animation frames.

Kept in the repo (not just the output PNGs) so every visual asset is
reproducible from source, in keeping with FROST's "no unexplained
binaries" principle — regenerate anytime with:

    python branding/tools/generate_assets.py

Requires Pillow (`pip install Pillow`). Uses a system monospace font for
the rasterized ASCII logo; falls back to Pillow's built-in bitmap font
if none of the common ones are found (uglier, but still works).
"""
import math
import os

from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
GRUB_DIR = os.path.join(HERE, "..", "grub")
PLYMOUTH_FRAMES_DIR = os.path.join(HERE, "..", "plymouth", "frames")
PLYMOUTH_DIR = os.path.join(HERE, "..", "plymouth")

# Glacier palette
BG_TOP = (5, 8, 12)          # near-black
BG_BOTTOM = (10, 40, 64)      # deep glacier blue
GLOW = (60, 140, 190)          # soft cyan-blue glow behind the logo
ICE = (170, 225, 250)           # bright ice-blue for logo/snow
ICE_DIM = (110, 175, 210)

FROST_ASCII = [
    r" ███████╗██████╗  ██████╗ ███████╗████████╗",
    r" ██╔════╝██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝",
    r" █████╗  ██████╔╝██║   ██║███████╗   ██║",
    r" ██╔══╝  ██╔══██╗██║   ██║╚════██║   ██║",
    r" ██║     ██║  ██║╚██████╔╝███████║   ██║",
    r" ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝",
    r"        minimalist Arch for full-stack devs",
]

FONT_CANDIDATES = [
    r"C:\Windows\Fonts\consola.ttf",
    r"C:\Windows\Fonts\CascadiaMono.ttf",
    r"C:\Windows\Fonts\lucon.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
]


def find_font(size):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


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


def make_logo():
    font = find_font(28)
    # Measure with a scratch image
    scratch = Image.new("RGBA", (10, 10))
    d = ImageDraw.Draw(scratch)
    line_h = font.getbbox("Mg")[3] + 6
    width = max(d.textlength(line, font=font) for line in FROST_ASCII)
    width = int(width) + 20
    height = line_h * len(FROST_ASCII) + 20

    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for i, line in enumerate(FROST_ASCII):
        color = ICE if i < len(FROST_ASCII) - 1 else ICE_DIM
        d.text((10, 10 + i * line_h), line, font=font, fill=color + (255,))

    out = os.path.join(GRUB_DIR, "frost-logo.png")
    img.save(out, optimize=True)
    print(f"wrote {out} ({img.width}x{img.height}, {os.path.getsize(out) // 1024} KiB)")
    return img.size


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
    make_logo()
    make_plymouth_background()
    make_plymouth_frames()
    print("done.")
