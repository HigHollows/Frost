# FROST — Phase 3 : utilisateurs, profils, ISO

Suite de `frost-build.sh` (Phase 1) + `frost-phase2.sh` (Phase 2). C'est la phase qui rend le système **réellement bootable** (hostname, locale, timezone, fstab, bootloader), ajoute un **compte utilisateur standard**, un **profil optionnel** (desktop léger / serveur headless), et génère un **profil archiso** pour produire une ISO FROST live.

---

## Ce que fait le script

### 1. Finalisation système *(mode bootstrap uniquement)*

Ces étapes n'existaient pas en Phase 1/2 — sans elles, un rootfs pacstrap'é n'est pas démarrable :

- `--hostname` → `/etc/hostname` + `/etc/hosts`
- `--locale` → décommente la locale dans `/etc/locale.gen`, lance `locale-gen`, écrit `/etc/locale.conf`
- `--timezone` → symlink `/etc/localtime`, `hwclock --systohc` (non-fatal si échoue, ex. pas d'accès RTC dans l'environnement de build)
- `genfstab -U` → `/etc/fstab` (basé sur ce qui est monté sous `--target`, aucune supposition sur le partitionnement)
- **Bootloader** : détecte UEFI (`/sys/firmware/efi/efivars`) vs BIOS sur l'hôte.
  - UEFI → `systemd-boot` (`bootctl install` + entrée `loader/entries/frost.conf` avec le `PARTUUID` de la racine). Nécessite que l'ESP soit déjà montée sur `--target/boot` ou `--target/efi` — sinon le script s'arrête avec des instructions claires, sans deviner un partitionnement.
  - BIOS → `grub` (`grub-install` sur le disque parent + `grub-mkconfig`).
  - `--bootloader none` pour tout sauter explicitement (avec avertissement clair que le système ne sera pas bootable).

En **mode local**, toutes ces étapes sont **sautées avec un warning** — on ne touche jamais au hostname/locale/bootloader d'une machine déjà en cours d'exécution.

### 2. Compte utilisateur standard

```bash
sudo ./frost-phase3.sh --target /mnt --username tristan --fullname "Tristan Lefebvre"
```

- Crée l'utilisateur (`useradd -m -G wheel,docker`), ou s'assure juste des groupes s'il existe déjà.
- **Le mot de passe n'est jamais un argument CLI** (visible dans `ps`/l'historique) : il est demandé de façon interactive (`read -s`, saisie masquée, confirmation), puis transmis à `chpasswd` via **stdin** — jamais loggé, jamais en clair sur la ligne de commande.
- En environnement non-interactif (pas de TTY), le compte est **verrouillé** (`passwd -l`) plutôt que de planter ou d'accepter un mot de passe non sécurisé — à définir ensuite avec `passwd <user>`.
- Active `%wheel ALL=(ALL:ALL) ALL` dans `/etc/sudoers`, avec **validation `visudo -c` avant d'accepter la modif** — restauration immédiate du fichier original si la syntaxe est invalide (jamais de sudoers cassé).
- Mot de passe root : proposé par défaut (même mécanisme sécurisé), `--skip-root-password` pour ne pas y toucher, ou `--lock-root` pour désactiver complètement la connexion root (recommandé une fois le compte sudo opérationnel).

### 3. Profils optionnels

| `--profile` | Paquets | Services activés |
|---|---|---|
| `desktop` | `xorg-server xorg-xinit i3-wm i3status dmenu alacritty picom feh lightdm lightdm-gtk-greeter pipewire pipewire-pulse wireplumber ttf-dejavu` | `lightdm.service` |
| `server` | `openssh ufw fail2ban` | `sshd.service`, `ufw.service` (+ règles par défaut : deny incoming, allow outgoing, allow ssh) |
| `none` (défaut) | — | — |

Choix volontairement minimalistes : i3 plutôt qu'un DE complet, pipewire plutôt que pulseaudio seul — cohérent avec l'esprit FROST.

### 4. Packaging ISO (archiso)

Génère un **profil archiso** (copié depuis `/usr/share/archiso/configs/releng`, personnalisé) dans `--iso-profile` (défaut `/opt/frost/iso/frost-releng`) :

- Branding (`profiledef.sh`) : nom, label `FROST_<AAAAMM>`, éditeur.
- `packages.x86_64` complété avec les paquets FROST **des dépôts officiels uniquement** (git, tmux, neovim, htop, python, docker, docker-compose, nodejs, npm).
- Les scripts `frost-build.sh` / `frost-phase2.sh` / `frost-phase3.sh` sont copiés dans `airootfs/opt/frost/scripts/` de l'ISO — la live ISO peut ainsi **s'installer elle-même** (comme l'ISO Arch officielle embarque `archinstall`).
- MOTD FROST à la connexion.

> **Important** : l'AUR (donc `yay`/`paru`, VSCode) **n'est pas inclus dans l'ISO** — `mkarchiso` ne construit qu'à partir des dépôts configurés (officiels), pas de l'AUR. Ça reste une étape post-install via `frost-phase2.sh`, exactement comme en Phase 2 — cohérent, pas de compilation AUR non supervisée dans une image "figée".

Par défaut, seul le **profil** est généré (`mkarchiso` n'est pas lancé — ça prend du temps et plusieurs Go d'espace disque). Ajoute `--build-iso` pour réellement construire l'ISO :

```bash
sudo ./frost-phase3.sh --skip-user --profile none --build-iso
# ISO produite dans /opt/frost/iso/out/
```

`--skip-iso` désactive complètement cette étape.

---

## Utilisation

```bash
# Build complet post Phase 1+2, sur une cible montée sur /mnt :
sudo ./frost-phase3.sh --target /mnt \
    --hostname frost \
    --timezone Europe/Paris \
    --username tristan --fullname "Tristan Lefebvre" \
    --profile desktop

# Juste générer le profil ISO, sans toucher à un disque cible :
sudo ./frost-phase3.sh --local --skip-user --profile none

# Simulation complète sans rien modifier :
sudo ./frost-phase3.sh --target /mnt --username tristan --profile server --dry-run
```

### Prérequis

- Root, réseau actif (paquets profil + archiso).
- Mode bootstrap : `--target` déjà partitionné/formaté/**monté**, y compris l'ESP sous `/boot` ou `/efi` si tu veux `systemd-boot`. FROST ne partitionne jamais un disque à ta place.
- `arch-install-scripts` (fournit `genfstab`) disponible sur l'ISO live par défaut.

---

## Sécurité & rollback

- **Aucun mot de passe en argument CLI ni en log** — saisie masquée + `chpasswd` via stdin uniquement.
- Compte non-interactif → **verrouillé**, jamais un mot de passe faible par défaut.
- `sudoers` toujours sauvegardé avant modif et **validé par `visudo -c`** ; restauration immédiate si invalide — le script ne laisse jamais un `sudoers` cassé.
- Les entrées utilisateur (`--username`, `--hostname`, `--locale`, `--timezone`, `--bootloader`, `--profile`) sont **validées par regex stricte** avant d'être interpolées dans les commandes chroot (défense en profondeur contre l'injection).
- `trap ERR` : restaure fstab/locale.gen/sudoers depuis leur backup, supprime les fichiers/dossiers créés par cette exécution, et **supprime le compte utilisateur** si sa création faisait partie de ce run en échec (jamais un compte pré-existant).

---

## Limitations connues (Phase 3)

- Le bootloader ne devine jamais le partitionnement : si l'ESP n'est pas montée, il s'arrête avec des instructions plutôt que de deviner.
- `ufw`/réseau : les règles sont écrites dans `/etc/ufw/` (persistantes), mais leur application "live" en chroot peut être un no-op selon l'environnement — elles s'appliquent réellement au premier vrai boot via `ufw.service`.
- L'ISO ne contient que des paquets des dépôts officiels ; AUR reste un post-install (`frost-phase2.sh`).
- Un seul profil à la fois (`desktop` XOR `server`) — pas de composition de profils pour l'instant.

---

## FROST est maintenant complet (Phases 1 → 3)

1. **Phase 1** (`frost-build.sh`) : socle Arch + toolchain dev + `/opt/frost/`
2. **Phase 2** (`frost-phase2.sh`) : helper AUR sécurisé + dotfiles + `frost-cli`
3. **Phase 3** (`frost-phase3.sh`) : hostname/locale/fstab/bootloader + compte utilisateur + profil + ISO

Prochaines pistes possibles (hors scope initial) : dépôt de paquets custom pour embarquer l'AUR dans l'ISO, désinstalleur/`frost-cli uninstall`, tests automatisés en VM (CI).
