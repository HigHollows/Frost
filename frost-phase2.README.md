# FROST — Phase 2 : AUR helper, dotfiles, frost-cli

Suite de `frost-build.sh` (Phase 1). Ce script suppose que le socle (base, dev toolchain, `/opt/frost/`) est déjà en place, mais fonctionne même si ce n'est pas le cas (juste un warning).

---

## Ce que fait le script

### 1. Helper AUR de confiance (`yay` ou `paru`)

- **Jamais construit en root.** Le script crée un utilisateur jetable `frostbuilder`, lui accorde un `sudo` **sans mot de passe limité à `/usr/bin/pacman` uniquement** (pas un blanket `ALL`), compile le paquet, puis **supprime l'utilisateur et la règle sudo** — succès ou échec.
- Source : dépôt AUR officiel du paquet `*-bin` (`yay-bin` ou `paru-bin`, précompilés — cohérent avec l'esprit minimaliste, pas besoin de toolchain Go/Rust).
- Si `yay`/`paru` est déjà présent, l'étape est simplement skip.
- `--skip-aur` désactive complètement cette étape (utile hors ligne ou en test).

> **Confiance** : le script clone `https://aur.archlinux.org/<pkg>-bin.git` — c'est le dépôt AUR officiel. Comme pour tout paquet AUR, tu es libre d'auditer le `PKGBUILD` avant de relancer si tu veux une vérification manuelle supplémentaire (le script ne le fait pas automatiquement, il n'y a pas de garantie de signature comme pour les repos officiels).

### 2. Dotfiles FROST par défaut

Déployés via un **bloc géré idempotent** (`# >>> FROST managed block >>> ... # <<< FROST managed block <<<`) : relancer le script ne duplique jamais le contenu, il remplace juste le bloc. Toute modif existante hors du bloc est préservée, et l'original est sauvegardé (`.frost-bak-<timestamp>`) avant toute écriture.

Fichiers concernés, écrits dans `/etc/skel/` (donc appliqués à tout nouveau compte créé ensuite) :

| Fichier | Contenu |
|---|---|
| `.bashrc` | alias (`ll`, `gs`, `gl`, `dco`, `dps`), `EDITOR=nvim`, prompt coloré |
| `.tmux.conf` | souris activée, historique 10k, status bar cyan |
| `.gitconfig` | `main` par défaut, `pull.rebase=false`, alias `co/st/lg` |
| `.config/nvim/init.vim` | numéros de ligne, indentation 2 espaces, clipboard système |

Avec `--user <nom>` (ou automatiquement via `$SUDO_USER` en mode local), les mêmes fichiers sont **aussi** copiés dans le `$HOME` de cet utilisateur existant, avec `chown` correct.

### 3. `frost-cli`

Écrit dans `/opt/frost/bin/frost-cli`, symlinké vers `/usr/local/bin/frost` (donc dans le `PATH`) :

```bash
frost status    # affiche les phases FROST complétées (lit /opt/frost/state/*.marker)
frost doctor    # check santé : espace disque, docker actif?, helper AUR présent?
frost update     # pacman -Syu + yay/paru -Syu
frost version    # version du cli
frost help        # aide
```

---

## Utilisation

```bash
sudo ./frost-phase2.sh                       # mode auto (bootstrap si /mnt monté avec pacstrap dispo, sinon local)
sudo ./frost-phase2.sh --local                # forcer le mode local
sudo ./frost-phase2.sh --target /mnt          # bootstrap explicite (après frost-build.sh --target /mnt)
sudo ./frost-phase2.sh --helper paru          # paru au lieu de yay
sudo ./frost-phase2.sh --user tristan          # applique aussi les dotfiles à cet utilisateur
sudo ./frost-phase2.sh --skip-aur --dry-run    # simulation sans build AUR
```

### Prérequis

- Root.
- Réseau actif (clone AUR + `pacman -Syu`).
- En mode bootstrap : la cible doit avoir tourné `frost-build.sh` (ou au moins avoir `sudo`, `git`, `base-devel` disponibles/installables) et être montée.
- `--user` doit être un utilisateur **déjà existant** sur le système (le script ne crée pas de comptes utilisateurs — ce sera Phase 3 le cas échéant).

---

## Sécurité & rollback

- Le build AUR n'accorde **jamais** de sudo illimité — uniquement `pacman`, uniquement au user jetable, uniquement le temps du build.
- L'utilisateur `frostbuilder` et la règle sudoers associée sont supprimés en fin de build, que ça réussisse ou échoue (`trap ERR` + nettoyage explicite).
- Toute dotfile écrasée est sauvegardée avant modification et restaurée automatiquement en cas d'échec du script.
- Copie temporaire de `resolv.conf` dans le chroot cible (mode bootstrap uniquement, nécessaire pour que `git clone` résolve `aur.archlinux.org`) — sera régénérée normalement par NetworkManager au premier vrai boot, ce n'est pas une donnée figée dans l'image.

---

## Limitations connues (Phase 2)

- Ne crée pas de nouveaux comptes utilisateurs (uniquement le build user `frostbuilder`, éphémère).
- Pas de vérification de signature/checksum du `PKGBUILD` AUR au-delà de ce que `makepkg`/`pacman` font par défaut.
- `init.vim` reste volontairement minimal, sans gestionnaire de plugins — cohérent avec l'esprit "minimaliste" de FROST.

---

## Prochaine phase (aperçu)

- **Phase 3** : profils optionnels (desktop léger / serveur headless), création de comptes utilisateurs standard, packaging ISO via `archiso`.
