# FROST — Phase 1: Fondations

Script de build pour **FROST**, une distro Arch Linux minimaliste pensée pour les devs full-stack.

Ce document couvre uniquement `frost-build.sh` (Phase 1). Les phases suivantes (AUR helper, dotfiles, desktop optionnel, ISO packaging) viendront ensuite.

---

## Ce que fait le script

1. **Détection d'architecture** — `x86_64` ou ARM (`aarch64` / `armv7l`), adapte la liste de dépôts et de paquets en conséquence (pas de `multilib` sur ARM, pas de `linux-firmware` générique sur ARM).
2. **Configuration pacman** — active `Color`, `ILoveCandy`, `ParallelDownloads = 10`, et le dépôt `multilib` (x86_64 uniquement). Sauvegarde `pacman.conf` avant modification.
3. **Socle minimal** — installe `base linux linux-firmware sudo networkmanager` (adapté sur ARM).
4. **Toolchain dev full-stack** :
   - `git`, `curl`, `wget`, `htop`, `tmux`, `neovim`, `python`, `python-pip`
   - `docker`, `docker-compose` (services activés)
   - `nodejs`, `npm`
   - `code` (VSCode) : **non installé automatiquement** — c'est un paquet AUR (`visual-studio-code-bin`), le script affiche les commandes `yay`/`paru` à lancer manuellement plutôt que de supposer un helper AUR de confiance.
5. **Structure `/opt/frost/`** : `bin/`, `config/`, `scripts/`, `cache/`, `logs/`, `state/` (+ un marqueur de phase dans `state/phase1.marker`).
6. **Gestion d'erreurs / rollback** : tout est tracé avec `set -euo pipefail` + un `trap ERR`. En cas d'échec, le script :
   - restaure le `pacman.conf` d'origine,
   - supprime les dossiers `/opt/frost/*` créés pendant *cette* exécution (jamais ceux préexistants),
   - démonte proprement la cible en mode bootstrap.

Tous les messages sont préfixés et colorés (`ROUGE` = fatal, `JAUNE` = warning, `VERT` = ok, `CYAN` = info) et dupliqués dans un log horodaté sous `/tmp/frost-build-<date>.log`.

---

## Deux modes d'exécution (auto-détectés)

| Mode | Quand | Effet |
|---|---|---|
| **bootstrap** | Lancé depuis l'ISO live Arch (`pacstrap` disponible) | Construit un rootfs neuf via `pacstrap` sur `--target` (défaut `/mnt`), qui doit déjà être partitionné/formaté/monté |
| **local** | Lancé sur un système Arch déjà installé, ou avec `--local` | Installe directement les paquets sur la machine hôte — pratique pour tester le script sans repartitionner |

---

## Utilisation

```bash
sudo ./frost-build.sh
```

### Options

```bash
sudo ./frost-build.sh --target /mnt      # cible pacstrap explicite (mode bootstrap)
sudo ./frost-build.sh --local             # force le mode local (installe sur le système courant)
sudo ./frost-build.sh --dry-run           # affiche les actions sans rien modifier
```

### Prérequis

- Root (`sudo` ou déjà `root`).
- Arch Linux (ou ISO live Arch) — le script vérifie la présence de `pacman`.
- **Mode bootstrap uniquement** : la cible (`--target`, défaut `/mnt`) doit déjà être partitionnée, formatée et **montée** avant de lancer le script — FROST Phase 1 ne touche pas au partitionnement disque.
- Connexion réseau active (`pacman -Syy` et `pacstrap` ont besoin d'internet).

### Exemple — build complet depuis l'ISO live

```bash
# Après avoir partitionné/formaté et monté le disque cible :
mount /dev/sda2 /mnt
mkdir -p /mnt/boot && mount /dev/sda1 /mnt/boot

# Puis :
sudo ./frost-build.sh --target /mnt
```

### Exemple — test rapide sur une VM Arch déjà installée

```bash
sudo ./frost-build.sh --local --dry-run   # voir ce qui serait fait
sudo ./frost-build.sh --local              # exécuter pour de vrai
```

---

## Rollback / sécurité

- Le script ne supprime **jamais** de fichiers hors de `/opt/frost/*` ou de la cible pacstrap.
- `pacman.conf` est toujours sauvegardé (`pacman.conf.frost-bak-<timestamp>`) avant modification ; restauré automatiquement en cas d'échec.
- En mode bootstrap, un échec démonte proprement `$FROST_TARGET` (`umount -R`) pour éviter de laisser le disque dans un état bancal.
- `Ctrl+C` est intercepté proprement (code de sortie 130), sans déclencher un rollback partiel incohérent.

Si un rollback automatique échoue (ex : `pacman.conf` non restaurable), le script te le signale explicitement en rouge avec le chemin du backup à restaurer manuellement.

---

## Limitations connues (Phase 1)

- Pas de partitionnement/formatage automatique du disque — volontaire, pour rester safe par défaut.
- VSCode n'est pas auto-installé (paquet AUR) ; le script log les commandes à lancer soi-même.
- Sur ARM, la liste de paquets est réduite (pas de `multilib`, firmware générique sauté) — à adapter selon la carte cible.
- Pas encore de génération d'ISO — Phase 1 pose le socle système + tooling, l'empaquetage ISO arrive en phase ultérieure.

---

## Prochaines phases (aperçu)

- **Phase 2** : bootstrap d'un helper AUR de confiance (`yay`/`paru`), dotfiles FROST par défaut, `frost-cli` dans `/opt/frost/bin/`.
- **Phase 3** : profils optionnels (desktop léger, serveur headless), packaging ISO via `archiso`.
