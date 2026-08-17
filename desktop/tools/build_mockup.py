#!/usr/bin/env python3
"""Builds the FROST OS Desktop mockup artifact by injecting the real
generated logo/wallpaper PNGs into the HTML template as base64 data
URIs. Keeps the giant base64 blobs out of the template source file.
"""
import base64
import os

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, "mockup_template.html")
LOGO = os.path.join(HERE, "..", "..", "branding", "grub", "frost-logo.png")
WALLPAPER = os.path.join(HERE, "..", "wallpaper", "frost-wallpaper.png")
SCRATCHPAD = r"C:\Users\33771\AppData\Local\Temp\claude\C--Users-33771-Documents-Frost-distro\6dd88604-977e-46f1-bdb9-9f6a44b09a5e\scratchpad"
OUT = os.path.join(SCRATCHPAD, "frost-os-desktop-mockup.html")


def b64(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode("ascii")


def main():
    html = open(TEMPLATE, encoding="utf-8").read()
    html = html.replace("__LOGO_B64__", b64(LOGO))
    html = html.replace("__WALLPAPER_B64__", b64(WALLPAPER))
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"wrote {OUT} ({os.path.getsize(OUT) // 1024} KiB)")


if __name__ == "__main__":
    main()
