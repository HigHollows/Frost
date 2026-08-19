#!/usr/bin/env python3
"""Generates FROST's alternate color presets (theme variants) from the
canonical FROST Mono source files — same reproducible-from-code approach
as generate_wallpaper.py. Regenerate anytime:

    python desktop/tools/generate_theme_variants.py

REDESIGN NOTE (2026-08 mini-refonte): the preset lineup used to be four
loosely-related palettes (Blue/Noir/Aurora/Midnight), and the default
leaned neon (#00d9ff cyan everywhere). It's now one sober neutral base
— frost-mono, the canonical source files themselves, near-black/white/
gray with no hue in the accent — plus three muted (never neon) accent
swaps: frost-blue, frost-green, frost-mustard. All four presets share
the *exact same* background/surface/text colors; only accent/accent_2
differ. That's a real "pick an accent chip" system, not four unrelated
themes wearing the same shape.

Why generated rather than hand-written: desktop/theme/gtk-4.0/gtk.css and
desktop/extension/frost-shell@frost-os/stylesheet.css are the single
source of truth for FROST's *shape* (radius, motion, focus rings, layout)
— that shouldn't fork four ways every time a spacing value changes. Only
the *palette* differs between presets, so this script does a careful,
whole-token find/replace of the canonical palette's colors (in both hex
and the decimal-rgb form the Shell stylesheet uses for `rgba()`) against
each preset's palette, and writes the result out untouched otherwise.

HONEST SCOPE: this covers the two files frost-desktop.sh actually
installs (the GTK4 theme and the Shell extension's stylesheet). It does
NOT touch org.gnome.desktop.interface's `accent-color` — that's a fixed
GNOME palette (blue/teal/green/yellow/orange/red/pink/purple/slate), not
an arbitrary hex, so each variant below also gets an `accent-color` file
naming the closest built-in match; frost-theme (the switcher script)
applies it via gsettings alongside the CSS swap.
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.join(HERE, "..", "..")
GTK_BASE = os.path.join(HERE, "..", "theme", "gtk-4.0", "gtk.css")
INDEX_THEME_BASE = os.path.join(HERE, "..", "theme", "index.theme")
SHELL_BASE = os.path.join(HERE, "..", "extension", "frost-shell@frost-os", "stylesheet.css")
OUT_DIR = os.path.join(HERE, "..", "theme-variants")

# Canonical (FROST Mono) palette — must match desktop/theme/gtk-4.0/gtk.css
# and stylesheet.css's `stage {}` block exactly, or the substitution below
# silently does nothing.
CANONICAL = {
    "bg_dark": "#0d0d0d",
    "surface_1": "#1a1a1a",
    "surface_2": "#262626",
    "accent": "#e6e6e6",
    "accent_2": "#b0b0b0",
    "text_primary": "#f2f2f2",
    "text_secondary": "#9a9a9a",
}

# danger/success are semantic (error/success states) and deliberately
# constant across every preset — a red error stays legible-as-an-error
# regardless of which accent color the user picked.
#
# Every preset below shares CANONICAL's bg_dark/surface_1/surface_2/
# text_primary/text_secondary — only accent/accent_2 change. Deliberate:
# this is meant to read as "one sober theme, pick your accent chip", not
# four different moods.

_BASE = {k: v for k, v in CANONICAL.items() if k not in ("accent", "accent_2")}

PRESETS = {
    "frost-mono": {
        "display_name": "FROST Mono",
        "palette": CANONICAL,  # identity — this *is* the canonical file
        "accent_color": "slate",
    },
    "frost-blue": {
        "display_name": "FROST Blue",
        "palette": {**_BASE, "accent": "#4a72a8", "accent_2": "#6f93bf"},
        "accent_color": "blue",
    },
    "frost-green": {
        "display_name": "FROST Green",
        "palette": {**_BASE, "accent": "#4a8f66", "accent_2": "#6fab87"},
        "accent_color": "green",
    },
    "frost-mustard": {
        "display_name": "FROST Mustard",
        "palette": {**_BASE, "accent": "#b8923f", "accent_2": "#cfab63"},
        "accent_color": "yellow",
    },
}


def hex_to_rgb_tuple_str(hex_color):
    """'#00d9ff' -> '0, 217, 255' (the decimal form stylesheet.css uses
    inside rgba(...) literals)."""
    h = hex_color.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return f"{r}, {g}, {b}"


def build_replacements(preset_palette):
    """Longest-first list of (old, new) string pairs covering both the
    hex and decimal-rgb forms of every palette token."""
    pairs = []
    for key, canonical_hex in CANONICAL.items():
        new_hex = preset_palette[key]
        pairs.append((canonical_hex, new_hex))
        pairs.append((hex_to_rgb_tuple_str(canonical_hex), hex_to_rgb_tuple_str(new_hex)))
    # Longest strings first so e.g. a decimal triple that's a substring
    # of another never gets partially clobbered.
    pairs.sort(key=lambda p: -len(p[0]))
    return pairs


def apply_replacements(text, pairs):
    for old, new in pairs:
        text = text.replace(old, new)
    return text


def generate():
    with open(GTK_BASE, encoding="utf-8") as f:
        gtk_base = f.read()
    with open(SHELL_BASE, encoding="utf-8") as f:
        shell_base = f.read()
    with open(INDEX_THEME_BASE, encoding="utf-8") as f:
        index_theme_base = f.read()

    for slug, preset in PRESETS.items():
        pairs = build_replacements(preset["palette"])

        out_dir = os.path.join(OUT_DIR, slug)
        gtk4_dir = os.path.join(out_dir, "gtk-4.0")
        os.makedirs(gtk4_dir, exist_ok=True)

        gtk_out = apply_replacements(gtk_base, pairs)
        with open(os.path.join(gtk4_dir, "gtk.css"), "w", encoding="utf-8", newline="\n") as f:
            f.write(gtk_out)

        shell_out = apply_replacements(shell_base, pairs)
        with open(os.path.join(out_dir, "shell-stylesheet.css"), "w", encoding="utf-8", newline="\n") as f:
            f.write(shell_out)

        index_out = re.sub(r"(?m)^Name=.*$", f"Name={preset['display_name']}", index_theme_base)
        with open(os.path.join(out_dir, "index.theme"), "w", encoding="utf-8", newline="\n") as f:
            f.write(index_out)

        with open(os.path.join(out_dir, "accent-color"), "w", encoding="utf-8", newline="\n") as f:
            f.write(preset["accent_color"] + "\n")

        print(f"wrote {slug} -> {out_dir}")


if __name__ == "__main__":
    generate()
    print("done.")
