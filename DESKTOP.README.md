# FROST OS Desktop

A themed GNOME Shell desktop — not a custom-built compositor/shell. Read [the note below](#why-gnome-shell-instead-of-building-a-new-shell) before anything else; it explains a real scope decision, not a shortcut taken quietly.

## Why GNOME Shell instead of building a new shell

The original spec for this asked for a full custom desktop shell: a top bar, dock, quick-settings panel, notification system, file manager, launcher, and window management, all hand-built in GTK4/Qt6, hitting GNOME-Shell-competitive polish. That is realistically a multi-month, multi-person engineering project — GNOME Shell itself is hundreds of thousands of lines refined over 15+ years. Nothing in this repo was going to responsibly replicate that from scratch in one sitting, especially with **no Wayland/GNOME runtime available to actually run and test any of it**.

The spec's own dependency list — Wayland, systemd, PipeWire, NetworkManager, **Mutter**, GTK4 + Libadwaita — is *already GNOME's stack*. So `frost-desktop.sh` doesn't build a new shell; it installs GNOME Shell (Mutter is its compositor) and re-skins it:

| What the spec asked for | What this actually is |
|---|---|
| Top bar | GNOME's panel, restyled (`stylesheet.css`) |
| Dock | [Dash to Dock](https://extensions.gnome.org/extension/307/dash-to-dock/) — a real, mature, widely-used extension, configured via dconf, not reimplemented |
| Quick settings panel | GNOME's native Quick Settings (built in since GNOME 43) — already the 2×4-toggle, slide-out-from-top-right thing described; restyled, not rebuilt |
| Notifications | GNOME's built-in notification banners, restyled |
| Launcher ("Spotlight-style") | GNOME's Activities overview (Super key already opens it) |
| File manager | Nautilus (Files) — GTK4/Libadwaita-native already |
| Terminal dropdown | [Guake](http://guake-project.org/), configured with the FROST palette/font |
| Glassmorphism blur | [Blur my Shell](https://extensions.gnome.org/extension/3193/blur-my-shell/) — real GL/Clutter blur; St (Shell) CSS alone cannot do `backdrop-filter` |
| FROST-specific bits | `frost-shell@frost-os` — a small custom extension: Steam Mode quick toggle, a panel indicator, the hidden easter egg |
| Performance monitor | [Vitals](https://extensions.gnome.org/extension/1460/vitals/) — real CPU/RAM/GPU/temp panel extension, not reimplemented |
| Power modes | `power-profiles-daemon` — GNOME's native Performance/Balanced/Power Saver Quick Settings entry, no extension needed |
| Color presets | 4 real palettes (FROST Blue/Noir/Aurora/Midnight), switchable via `frost-theme` — see [Color presets](#color-presets) below |
| Clipboard manager | [Clipboard Indicator](https://extensions.gnome.org/extension/779/clipboard-indicator/) — real, established extension, 50-item history |
| Notes | GNOME Notes (Bijiben) — a real app, not a floating always-on-top widget (GNOME has no built-in equivalent to a pinned sticky note) |
| Screenshot & recording | GNOME Shell's own built-in tools — `PrtScn` for the screenshot UI, `Ctrl+Shift+Alt+R` for screen recording. No package to install, no competing tool added — see [Keyboard shortcuts](#keyboard-shortcuts) |

This is the honest, buildable version of the spec's intent: FROST's own visual identity, on a foundation that's actually maintained by someone else and battle-tested by millions of GNOME users, rather than a bespoke shell nobody has run yet.

## What's verified vs. not

| Component | Status |
|---|---|
| `frost-desktop.sh` (the installer script) | Syntax-checked (`bash -n`), follows the same conventions as every other FROST script |
| `desktop/theme/gtk-4.0/gtk.css` | Valid GTK4 CSS syntax; colors/contrast reasoned through, not rendered |
| `desktop/extension/.../extension.js` | **VM-validated (2026-08)**, `State: ACTIVE`, zero errors — the FROST panel menu and Steam Mode quick toggle both confirmed working live. Getting there took fixing three real runtime bugs Node's syntax check never could have caught (stale `shell-version`, missing `settings-schema`, wrong `addExternalIndicator()` contract) — see ARCHITECTURE.md Lesson 7 |
| `desktop/extension/.../stylesheet.css` | `#panel`, `.quick-settings`, `.notification-banner`, `.overview`, `.search-entry`, `.dash` all VM-confirmed rendering correctly. The `#dashtodockContainer` hex-accent rules (added in the signature-identity pass) are newer and not yet re-verified the same way |
| `desktop/config/dconf-frost-defaults.ini` | **VM-validated** — `dconf load` confirmed applying the theme/wallpaper/extensions live (see ARCHITECTURE.md Lesson 6 for a real bug that blocked this until fixed). The `org/guake/*` section is still lower-confidence — verify against the installed Guake version |
| `desktop/wallpaper/frost-wallpaper.png` | Generated, viewed, and VM-confirmed rendering (hex-facet pattern added in the signature-identity pass) |
| `desktop/theme-variants/*` + `frost-theme` CLI | **VM-confirmed** — switching to FROST Noir correctly updated GTK4 CSS, Shell CSS, and `accent-color`; live palette change confirmed after relogin |
| `power-profiles-daemon` (power modes) | Package install + service enable only — the native GNOME Quick Settings entry it provides is well-established elsewhere, not separately re-verified here |
| Vitals (performance monitor) | Package/dconf install only — not yet loaded into a live session the way `frost-shell` was |
| `frost-desktop.sh`'s GDM fixes (`disable_motd_on_gdm`, `remove_gdm_arch_logo`) | **VM-confirmed** — applied live, screenshots show a clean greeter (no logo, no garbled text) |
| Clipboard Indicator | **VM-confirmed** — installed via AUR, enabled via dconf, panel icon visible and rendering after a clean relogin |
| GNOME Notes (Bijiben) | **VM-confirmed** — installed, `favorite-apps` dconf pin resolved correctly, icon visible in the dock |

**Still open**: the FROST panel indicator's own hex icon (`icons/frost-hex.svg`) renders at a size/contrast that's hard to see against the dark panel in practice, even though the button itself is confirmed present and clickable (opens the FROST OS menu). Cosmetic, not functional — worth another pass with a bolder/filled glyph.

## Installing

```bash
sudo ./frost-desktop.sh --target /mnt --username you
sudo ./frost-desktop.sh --local
```

⚠️ **Alternative to, not combined with**, `frost-phase3.sh --profile desktop` (which installs Xorg + i3 + lightdm). Running both installs two display managers and two window-manager stacks fighting for the same session. If you want the FROST OS GNOME experience, run Phase 3 with `--profile none` or `--profile server` first.

Depends on `frost-phase2.sh` (AUR helper — Dash to Dock/Blur my Shell may need it) and `frost-phase3.sh` (a real user for the extension/dconf steps, which need a home directory to write into).

## Palette

| Token | Hex | Use |
|---|---|---|
| `frost-bg-dark` | `#0f1419` | Window/base background |
| `frost-surface-1` | `#1a2332` | Panels, headerbars, dock |
| `frost-surface-2` | `#243447` | Cards, entries, borders |
| `frost-accent` | `#00d9ff` | Accent, focus rings, active states |
| `frost-accent-2` | `#4da6ff` | Secondary accent |
| `frost-text-primary` | `#f0f4f8` | Primary text (~17:1 contrast on bg — AAA) |
| `frost-text-secondary` | `#a8b8c8` | Secondary/dim text (~8.6:1 — AA) |
| `frost-danger` | `#ff6b6b` | Destructive actions |
| `frost-success` | `#51cf66` | Success states |

Defined once in `desktop/theme/gtk-4.0/gtk.css` (`@define-color`) and mirrored in `desktop/extension/frost-shell@frost-os/stylesheet.css` (St CSS custom properties) — if you change the palette, update both.

## Color presets

FROST Blue (above) isn't the only option — `frost-desktop.sh` also installs 3 alternate presets, generated from the canonical FROST Blue files by `desktop/tools/generate_theme_variants.py` (single source of truth for *shape*; only the palette is substituted per preset — see that script's own docs for why):

| Preset | Background | Accent | Notes |
|---|---|---|---|
| **FROST Blue** (default) | `#0f1419` | `#00d9ff` cyan | The palette documented above |
| **FROST Noir** | `#000000` pure black | `#cccccc` gray | Monochrome, no color at all |
| **FROST Aurora** | `#0f1419` | `#ff00ff` magenta / `#00ff88` green | Two-tone, high contrast |
| **FROST Midnight** | `#0a0e12` (darker than Blue) | `#4da6ff` blue | Subtler, cooler than Blue |

Switch with the installed `frost-theme` CLI:

```bash
frost-theme list              # see what's installed, and which is active
frost-theme frost-noir         # switch — updates GTK4 apps + Shell chrome + accent-color
frost-theme current            # show the active preset
```

GTK4 apps pick up the new palette on next launch. GNOME Shell chrome (top bar, quick settings, notifications) needs a reload: `Alt+F2` → `r` → Enter on X11, or a full logout/login on Wayland (Mutter doesn't support live Shell CSS reload on Wayland — a real GNOME limitation, not a FROST one). **VM-confirmed (2026-08)**: switching to FROST Noir correctly updated `org.gnome.desktop.interface accent-color` and both CSS files; a full relogin showed the new palette live.

## Customizing

- **App-level colors**: edit `desktop/theme/gtk-4.0/gtk.css`, then `dconf write /org/gnome/desktop/interface/gtk-theme "'FROST'"` or just re-copy to `~/.config/gtk-4.0/gtk.css` (the path GTK4 always loads regardless of theme name — see the file's own header comment for why that's the reliable path).
- **Shell chrome** (top bar, quick settings, notifications): edit `stylesheet.css`, then `Alt+F2` → `r` → Enter to reload the shell (X11 only — on Wayland, log out and back in).
- **Dock behavior**: `dconf-frost-defaults.ini`'s `[org/gnome/shell/extensions/dash-to-dock]` section, or Dash to Dock's own GUI settings (right-click the dock → "Dash to Dock Settings").
- **Wallpaper**: `python desktop/tools/generate_wallpaper.py` to regenerate from code (same reproducibility principle as `branding/tools/generate_assets.py`), or just drop in your own PNG and update the dconf `picture-uri`.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `Super` | Activities overview (app/file/command search) |
| `Ctrl+Alt+T` | Toggle Guake dropdown terminal |
| `Ctrl+Super+E` | 🥚 hidden — reveals a FROST easter egg notification |
| `Super+A` | Quick Settings (GNOME default) |
| `Super+V` | Notification list (GNOME default) |
| `Super+.` (period) | Clipboard Indicator's history popup (its own default, not remapped) |
| `PrtScn` | GNOME's built-in screenshot UI (full screen / selection / window) |
| `Ctrl+Shift+PrtScn` | Screenshot straight to clipboard, no UI |
| `Ctrl+Shift+Alt+R` | Start/stop GNOME's built-in screen recording — saved to `~/Videos`, a red dot appears in the top bar while recording |

## Accessibility

- Dark mode is the default (`color-scheme=prefer-dark`); light mode works too since the theme only overrides dark-mode-relevant Libadwaita colors — switching `color-scheme` to `default` falls back to stock Adwaita light.
- Contrast: primary text ~17:1, secondary text ~8.6:1 against the darkest background — both clear AA, primary is AAA.
- Focus states: `outline: 2px solid` the accent color on buttons/entries/rows (`gtk.css`), visible against every surface color in the palette.
- Motion: GNOME's `org/gnome/desktop/interface enable-animations` is the actual reduced-motion control point on this platform (there's no separate CSS-level `prefers-reduced-motion` query in GTK) — `frost-desktop.sh` doesn't force this off, but anyone who needs it can `gsettings set org.gnome.desktop.interface enable-animations false`.

## Performance — a reality check against the spec's targets

The original spec asked for `<200MB RAM` cold boot and `<2% CPU` idle. Those are **not realistic for GNOME Shell** — GNOME Shell alone typically idles somewhere around 400-800MB depending on version and enabled extensions (three are enabled here), and that's normal, not a FROST-specific problem. Claiming this setup hits those numbers would be a fabricated metric, so here it isn't:

| Metric | Spec target | Realistic GNOME Shell ballpark | Source |
|---|---|---|---|
| Cold boot RAM | <200MB | ~400-800MB | General GNOME Shell community reporting, not measured on this specific setup |
| Idle CPU | <2% | Similar, ~1-3% at rest | ditto |
| Animations | 60fps | Achievable with GPU accel (Mutter is hardware-accelerated by default) | — |

If `<200MB`/`<2%` is a hard requirement rather than an aspiration, the realistic path is a genuinely lightweight Wayland setup instead — **Sway** (i3-compatible, already the philosophy behind `frost-phase3.sh`'s `desktop` profile, just on Wayland instead of Xorg) + `waybar` (top bar) + `swaync` (notifications) + `nwg-dock`/`rofi` — which can plausibly idle in the 150-250MB range, at the cost of a more DIY, less visually-integrated result than GNOME gives out of the box. Not built here since GNOME was the chosen direction — flagged as a real option if the performance target turns out to matter more than the GNOME-level polish.

## Files

```
desktop/
  theme/
    index.theme
    gtk-4.0/gtk.css
  extension/frost-shell@frost-os/
    metadata.json
    extension.js
    stylesheet.css
    icons/frost-hex.svg
    schemas/org.gnome.shell.extensions.frost-shell.gschema.xml
  config/
    dconf-frost-defaults.ini
  wallpaper/
    frost-wallpaper.png
  theme-variants/                 generated: frost-blue/frost-noir/frost-aurora/frost-midnight
    frost-noir/gtk-4.0/gtk.css, shell-stylesheet.css, index.theme, accent-color
    ...
  tools/
    generate_wallpaper.py
    generate_theme_variants.py
    frost-theme                    installed to /opt/frost/bin, symlinked onto PATH
frost-desktop.sh
```

## Login screen (GDM)

`frost-desktop.sh` also fixes two real bugs found during VM testing that have nothing to do with the theme/extension code above, but everything to do with what the login screen actually shows — see ARCHITECTURE.md Lesson 8 for the full story:

- **No garbled text on the greeter.** GDM surfaces PAM session messages raw (no ANSI interpretation), and `gdm-password`/`gdm-autologin` inherited `pam_motd` from `system-login` — meant for shell logins, not a graphical greeter. `disable_motd_on_gdm()` rewrites just their session stack to drop `pam_motd`/`pam_mail`; `/etc/motd` itself is untouched and still shows in full color over SSH/tty.
- **No Arch Linux logo on the greeter.** Not controlled by `/etc/os-release`'s `LOGO=` field, despite that being the documented mechanism — Arch's `gdm` package hardcodes it via a gschema override. `remove_gdm_arch_logo()` ships a higher-priority override clearing it. No FROST logo is substituted in its place (matches what was actually asked for).
- `frost-branding.sh` separately rewrites `/etc/os-release` with FROST's own identity (`NAME`, `PRETTY_NAME="FROST Linux"`, `ID=frost`, `ID_LIKE=arch` — the standard way of crediting the base distro to tooling). GNOME's own About panel only renders `PRETTY_NAME`, not `ID_LIKE`, so the Arch credit doesn't show up as a visible line there — a GNOME limitation, confirmed in VM testing, not something worth patching `gnome-control-center` over. `hostnamectl` and `neofetch`-style tools do show it.
