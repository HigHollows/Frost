#!/usr/bin/env python3
"""Generates FROST's alternate color presets (theme variants) from the
canonical FROST Blue source files — same reproducible-from-code approach
as generate_wallpaper.py. Regenerate anytime:

    python desktop/tools/generate_theme_variants.py

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

# Canonical (FROST Blue) palette — must match desktop/theme/gtk-4.0/gtk.css
# and stylesheet.css's `stage {}` block exactly, or the substitution below
# silently does nothing.
CANONICAL = {
    "bg_dark": "#0f1419",
    "surface_1": "#1a2332",
    "surface_2": "#243447",
    "accent": "#00d9ff",
    "accent_2": "#4da6ff",
    "text_primary": "#f0f4f8",
    "text_secondary": "#a8b8c8",
}

# danger/success are semantic (error/success states) and deliberately
# constant across every preset — a red error stays legible-as-an-error
# regardless of which accent color the user picked.

PRESETS = {
    "frost-blue": {
        "display_name": "FROST Blue",
        "palette": CANONICAL,  # identity — this *is* the canonical file
        "accent_color": "blue",
    },
    "frost-noir": {
        "display_name": "FROST Noir",
        "palette": {
            "bg_dark": "#000000",
            "surface_1": "#141414",
            "surface_2": "#1f1f1f",
            "accent": "#cccccc",
            "accent_2": "#e0e0e0",
            "text_primary": "#ffffff",
            "text_secondary": "#b3b3b3",
        },
        "accent_color": "slate",
    },
    "frost-aurora": {
        "display_name": "FROST Aurora",
        "palette": {
            "bg_dark": "#0f1419",
            "surface_1": "#1a2332",
            "surface_2": "#243447",
            "accent": "#ff00ff",
            "accent_2": "#00ff88",
            "text_primary": "#f0f4f8",
            "text_secondary": "#a8b8c8",
        },
        "accent_color": "purple",
    },
    "frost-midnight": {
        "display_name": "FROST Midnight",
        "palette": {
            "bg_dark": "#0a0e12",
            "surface_1": "#141a22",
            "surface_2": "#1e2733",
            "accent": "#4da6ff",
            "accent_2": "#00d9ff",
            "text_primary": "#e8ecf0",
            "text_secondary": "#a0aab5",
        },
        "accent_color": "blue",
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
