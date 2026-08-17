# FROST — Boot & Aesthetic pack

Visual identity for FROST: GRUB theme, Plymouth boot splash, `/etc/motd`, and zsh aliases. Config files + generated assets live under [`branding/`](branding/); [`frost-branding.sh`](frost-branding.sh) installs all of it onto a target built by Phases 1-3.

```
branding/
  logo/
    frost-logo-source.png       the designer's original file, untouched, kept for provenance
    frost-logo.png                cleaned up: real alpha channel, black linework — for light backgrounds (README, docs)
  grub/
    theme.txt              GRUB2 graphical theme (background + crystal mark + menu colors)
    frost-grub.cfg           /etc/default/grub overrides (merged in, not overwritten)
    background.png            generated: black -> glacier-blue gradient, 1280x720
    frost-logo.png             derived from logo/frost-logo.png: ice-blue linework, sized for the theme
  plymouth/
    frost.plymouth            theme metadata
    frost.script                boot animation (Plymouth script language)
    background.png              same gradient as GRUB, full screen
    frost-logo.png               same ice-blue mark as the GRUB one, smaller
    lock.png                     dim "paused" snowflake, shown at a LUKS password prompt
    frames/frame1.png .. frame8.png   8-frame growing-snowflake animation
  motd/
    motd.template               /etc/motd template with {{TAG}} placeholders
    branding.conf.example        user-editable variables (tagline, version, fake error)
    frost-motd-render.sh          renders the template -> /etc/motd
  zsh/
    frost.zshrc                   aliases, prompt, colors — sourced, not copied per-user
  tools/
    generate_assets.py            regenerates every derived PNG above (`pip install Pillow` + run it)
```

### About the logo

`branding/logo/frost-logo-source.png` is the designer-provided file, kept untouched. It turned out to have **no real transparency** — its background was flattened into a very-light-gray checkerboard baked directly into the pixels instead of an alpha channel, which would've shown as a faint gray box around the mark wherever it was placed. `generate_assets.py` rebuilds a real alpha mask from it (dark linework → opaque, everything near-white → transparent) and recolors it per context: black on transparent for the README, ice-blue on transparent for GRUB/Plymouth. If you swap in a new source logo, make sure it actually exports with a genuine alpha channel — check with `Image.open(path).convert("RGBA").split()[3].getextrema()`; if that prints `(255, 255)`, there's no real transparency to work with either.

## ⚠️ Important: this depends on Phase 3, not just Phase 1

The GRUB theme needs GRUB **already installed** — which only happens in `frost-phase3.sh`'s bootloader step, and only when GRUB (not `systemd-boot`) was actually chosen. Wiring `frost-branding.sh` into `frost-build.sh` (Phase 1) would run it before any bootloader exists, so the GRUB half would just skip.

**Run it after Phase 3, as a 4th step:**

```bash
sudo ./frost-build.sh --target /mnt
sudo ./frost-phase2.sh --target /mnt
sudo ./frost-phase3.sh --target /mnt --username you --profile server
sudo ./frost-branding.sh --target /mnt
```

If you specifically want it folded into `frost-build.sh` as a single combined script, add this at the very end of `frost-build.sh`'s `main()`, **after** `create_frost_structure` — but note the GRUB portion will only take effect once Phase 3 has run and installed a bootloader; everything else (Plymouth, MOTD, zsh) works fine right after Phase 1's base system exists:

```bash
# In frost-build.sh, inside main(), after create_frost_structure:
if [[ -f "${SCRIPT_DIR}/frost-branding.sh" ]]; then
    "${SCRIPT_DIR}/frost-branding.sh" --target "$FROST_TARGET" --skip-grub
fi
```

(`--skip-grub` there because Phase 1 hasn't installed a bootloader yet — drop it once you also call `frost-branding.sh` again, without `--skip-grub`, after Phase 3.)

## systemd-boot users: what you actually get

FROST's UEFI default is `systemd-boot`, not GRUB — it has no theme engine (no images, no custom fonts, no menu colors). `frost-branding.sh` detects this via the Phase 3 marker and skips the GRUB step automatically rather than fail. What you still get in full on `systemd-boot`:

- **Plymouth splash** — completely independent of the bootloader, works the same either way.
- **`/etc/motd`, zsh aliases** — not bootloader-related at all.

The only thing systemd-boot can't replicate is the graphical GRUB menu itself. `frost-phase3.sh`'s `loader.conf` already sets `console-mode max`; if you want GRUB's visuals specifically, pass `--bootloader grub` to `frost-phase3.sh` even on UEFI (GRUB supports UEFI too) — that's a one-line change to `frost-phase3.sh`'s `install_bootloader()` to actually honor the flag on UEFI instead of forcing systemd-boot; not made here since it changes Phase 3's default behavior and wasn't asked for.

## Running it

```bash
sudo ./frost-branding.sh --target /mnt                       # everything
sudo ./frost-branding.sh --local                               # on an already-running FROST box
sudo ./frost-branding.sh --target /mnt --skip-plymouth          # pick and choose
sudo ./frost-branding.sh --target /mnt --tagline "built for ${USER}"
sudo ./frost-branding.sh --target /mnt --dry-run                  # preview
```

Flags: `--skip-grub`, `--skip-plymouth`, `--skip-motd`, `--skip-zsh`, `--tagline "<text>"`, `--font-package <name>` (override Nerd Font package auto-detection), `--dry-run`. Same rollback/backup safety model as the other three scripts (config backups before edit, only this run's own files removed on failure).

## Customizing after install

- **MOTD tagline / fake error**: edit `/etc/frost/branding.conf`, then `sudo /opt/frost/bin/frost-motd-render.sh`. Set `FROST_FAKE_ERROR=""` to remove the joke error line entirely.
- **zsh aliases**: edit `/etc/frost/frost.zshrc` directly (it's sourced live, no rebuild step). It doesn't change anyone's shell — `chsh -s /usr/bin/zsh <user>` to actually use it.
- **Regenerating the images**: `pip install Pillow && python branding/tools/generate_assets.py` — everything is generated from code, no binary asset is hand-crafted or unreproducible.

## Nerd Font note

`theme.txt` expects a font named `Frost Regular`, produced by converting a Nerd Font TTF with `grub-mkfont --name="Frost Regular"`. The install script tries a short list of likely Arch package names for Noto Sans Mono Nerd Font and **degrades gracefully** if none match your mirror's current naming (GRUB just falls back to its built-in font — colors and layout still apply). If it misses, find the right package yourself with `pacman -Ss nerd` and pass it via `--font-package <name>`.

## Plymouth technical notes

- Theme uses the `script` renderer (Plymouth's general-purpose scripting engine), not `two-step` or a canned theme — full control over the animation, still lightweight (8 small PNGs).
- Includes a minimal `SetDisplayPasswordFunction` handler so a future LUKS-encrypted root (see [ROADMAP.md](ROADMAP.md)) won't hit an unstyled password prompt.
- `frost-branding.sh` adds the `plymouth` hook to `/etc/mkinitcpio.conf` right after `udev` (its documented required position) and rebuilds the initramfs — this is the step that actually makes it show up at boot, not just installing the theme files.
