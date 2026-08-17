# FROST — Roadmap

## Done

- [x] **Phase 1 — Foundations** (`frost-build.sh`): arch detection, pacman tuning, base system, dev toolchain, `/opt/frost/` scaffold, colored failsafe logging with rollback
- [x] **Phase 2 — AUR & environment** (`frost-phase2.sh`): trusted AUR helper build (throwaway unprivileged user), idempotent default dotfiles, `frost-cli`
- [x] **Phase 3 — System & distribution** (`frost-phase3.sh`): hostname/locale/timezone/fstab, bootloader (systemd-boot/grub), standard sudo user, optional desktop/server profile, archiso live-ISO profile generation
- [x] End-to-end validation in a real VM: bootstrap → chroot provisioning → reboot → login, with `sudo`/`docker`/`sshd` confirmed working
- [x] Project docs: README, ARCHITECTURE, this roadmap, MIT license
- [x] **Boot & Aesthetic pack** (`frost-branding.sh`): GRUB theme, Plymouth splash, `/etc/motd`, zsh aliases — not yet VM-validated like Phases 1-3
- [x] **Security & Hacking Tools pack** (`frost-security.sh`): pentest toolkit (nmap/wireshark/metasploit/hashcat/aircrack-ng/hydra/sqlmap/john/nikto/gobuster/nuclei/burpsuite/w3af), ufw firewall, VPN templates, SSH hardening + fail2ban, optional Tor — not yet VM-validated
- [x] **Gaming & Dev Stack pack** (`frost-gaming.sh`): Steam/Lutris/Heroic/GameMode/MangoHud, GPU auto-detection (nvidia/amd/intel/virtual) + driver install + NVIDIA modeset tweak, full dev stack (rust/go/java/postgres/redis/mongo/vscode/jetbrains), sysctl + RAM disk + sensors tuning, `frost --mode gaming|dev` wired into frost-cli — not yet VM-validated
- [x] **Contribution guide.** [CONTRIBUTING.md](CONTRIBUTING.md) — commit message convention (emoji + type, full body posted to Discord) and the safety-model rules new code must follow.

## Next up

- [ ] **Bundle the AUR helper into the live ISO.** Right now `mkarchiso` only pulls from official repos, so `yay`/`paru`/VSCode stay a post-install step even on the built ISO. Standing up a small local package repo (`repo-add` + a custom `[frost]` entry in the ISO's `pacman.conf`) would let the ISO ship with the AUR helper preinstalled, without ever building AUR packages *inside* the image untracked.
- [ ] **CI boot test.** Automate what the VM validation pass did by hand: a GitHub Actions job that runs all three phases against a QEMU disk image headlessly and asserts it reaches a login prompt. Catches regressions like the `IFS` array-join bug automatically instead of relying on someone noticing in a manual test.
- [ ] **`frost-cli update` for the distro's own scripts**, not just packages — a `frost self-update` that re-syncs `/opt/frost/scripts/` from a pinned release.
- [ ] **`frost-cli uninstall` / rollback for Phase 2/3 changes** after the fact (not just mid-run failure rollback) — e.g. `frost-cli undo-profile` to cleanly remove a `desktop` profile's packages and re-enable a `server` one.
- [ ] **Desktop profile polish.** Current `desktop` profile (Xorg + i3 + lightdm + pipewire) is intentionally bare-bones. Worth a second, deliberately-configured pass: default i3 config with sane keybindings, a status bar, a picom config tuned for VMs vs. real hardware.
- [ ] **Disk encryption (LUKS) as an opt-in Phase 3 flag.** Currently FROST never touches partitioning/encryption — this would stay opt-in and explicit, consistent with "never guess the disk layout."
- [ ] **Secure Boot support** for the systemd-boot path (signed kernel/bootloader), for users who need it.
- [ ] **ARM validation.** The architecture-detection branch for `aarch64`/`armv7h` has never been run against real ARM hardware or a matching QEMU target — only reasoned about. Needs an actual test pass the way x86_64 got one.
- [ ] **Non-`en_US`/`UTC` presets.** `--locale`/`--timezone` already work for any valid value; a documented set of common presets (`fr_FR.UTF-8` + `Europe/Paris`, etc.) would save typing for non-US users.
- [ ] **VM-validate the Boot & Aesthetic, Security, and Gaming/Dev packs** the way Phases 1-3 were: run `frost-branding.sh`/`frost-security.sh`/`frost-gaming.sh` end-to-end in the VirtualBox VM, boot on real GRUB with the theme applied, confirm Plymouth actually renders, confirm the AUR-only tools (burpsuite/metasploit/nuclei/w3af/heroic/vscode/jetbrains-toolbox/mongodb) actually install through the delegated user, and confirm `frost --mode gaming|dev` actually flips services/governor as expected. The VM's virtual GPU is a good test of `frost-gaming.sh`'s "none/virtual" GPU-detection branch specifically.

## Explicitly out of scope (for now)

- A graphical installer / TUI — FROST is scripts-first by design (see [ARCHITECTURE.md](ARCHITECTURE.md#why-not-just-use-archinstall))
- Automatic disk partitioning — FROST never guesses a disk layout; you partition, FROST installs
- A rolling "FROST release" separate from upstream Arch — FROST is a provisioning layer on top of Arch, not a fork
