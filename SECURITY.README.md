# FROST — Security & Hacking Tools pack

⚠️ **Authorized use only.** Every tool below is dual-use. Only point them at systems, networks, or applications you **own** or have **explicit written authorization** to test — a signed pentest engagement, a CTF, your own home lab. Unauthorized scanning or access is a criminal offense in most jurisdictions. This document and [frost-security.sh](frost-security.sh) exist to set up a legitimate, well-configured toolkit — how you point it is entirely on you.

## Running it

```bash
sudo ./frost-security.sh --target /mnt                 # everything
sudo ./frost-security.sh --local                          # on an already-running FROST box
sudo ./frost-security.sh --target /mnt --enable-tor           # opt-in Tor
sudo ./frost-security.sh --target /mnt --dry-run                 # preview
```

Requires `frost-phase2.sh` to have run first (for the AUR helper — several tools here are AUR-only) and ideally `frost-phase3.sh` (for a real sudo user to delegate AUR builds and SSH hardening to; without one, those steps log clear instructions and skip rather than fail).

Flags: `--username <name>`, `--aur-helper <yay|paru>`, `--skip-tools`, `--skip-firewall`, `--skip-vpn`, `--skip-ssh-hardening`, `--enable-vpn-autoconnect`, `--enable-tor`, `--dry-run`. Same rollback/backup safety model as the rest of FROST.

## Tools installed, and how to start with each

Official-repo tools install straight via `pacman`. AUR-only ones (marked below) build through the Phase 2 AUR helper, delegated to a real non-root user — never as root, same rule as everywhere else in FROST.

| Tool | Source | Quick start |
|---|---|---|
| **nmap** | official | `nmap -sV -sC 192.168.1.0/24` — service/version + default script scan of a subnet you're authorized on |
| **wireshark** | official | `wireshark` (GUI) or `tshark -i eth0 -w capture.pcap` (CLI). frost-security.sh adds you to the `wireshark` group + sets `dumpcap`'s capabilities, so you don't need root for every capture |
| **hashcat** | official | `hashcat -m 0 -a 0 hashes.txt rockyou.txt` — mode 0 = MD5, dictionary attack. `-m` list: `hashcat --help` |
| **aircrack-ng** | official | `airmon-ng start wlan0` → `airodump-ng wlan0mon` → `aircrack-ng -w wordlist.txt capture.cap` |
| **hydra** | official | `hydra -l admin -P wordlist.txt ssh://192.168.1.10` — never against a host you don't own |
| **sqlmap** | official | `sqlmap -u "https://target/page?id=1" --batch --risk=1 --level=1` — start low-risk, escalate only if authorized |
| **john** | official | `john --wordlist=rockyou.txt hashes.txt`, then `john --show hashes.txt` |
| **nikto** | official / AUR fallback | `nikto -h https://target` — web server misconfig/vuln scan |
| **gobuster** | official / AUR fallback | `gobuster dir -u https://target -w wordlist.txt` (or `dns`/`vhost` modes) |
| **nuclei** | AUR (`nuclei-bin`) | `nuclei -u https://target -t cves/` — template-based scanning, keep templates updated: `nuclei -update-templates` |
| **burp-suite-community** | AUR (`burpsuite`) | Launch `burpsuite`, set your browser's proxy to `127.0.0.1:8080`, intercept in the Proxy tab |
| **metasploit-framework** | AUR (`metasploit`) | `msfconsole`, then `search <cve-or-name>`, `use <module>`, `set RHOSTS ...`, `run` |
| **w3af** | AUR (`w3af`) | ⚠️ largely unmaintained upstream (Python 2 era) — expect friction. `nuclei`/`nikto`/`gobuster` cover most of the same ground and are actively maintained; try `w3af_console` if you specifically need it |

## Firewall

`ufw` — default deny incoming, allow outgoing, allow SSH, logging on. Same baseline as `frost-phase3.sh`'s `server` profile (safe to run both; ufw just no-ops on an already-applied rule). Check status: `sudo ufw status verbose`.

## VPN — templates, not live configs

`frost-security.sh` installs **templates** to `/etc/wireguard/frost-wg0.conf.template` and `/etc/openvpn/client/frost-client.conf.template` — it never invents a working VPN config (there's no real server to point at). To actually use one:

1. Get real values from your VPN provider/server admin (WireGuard: your private key + the server's public key + endpoint; OpenVPN: the provider's `.ovpn` bundle).
2. Fill in the template, save it **without** the `.template` suffix in the same directory.
3. `sudo systemctl enable --now wg-quick@frost-wg0.service` (or `openvpn-client@frost-client.service`).

`--enable-vpn-autoconnect` only enables the WireGuard unit, and only if `/etc/wireguard/frost-wg0.conf` exists **and** no `<PLACEHOLDER>` markers remain in it — it will not enable a template as-is.

## SSH hardening

Drop-in at `/etc/ssh/sshd_config.d/99-frost-hardening.conf`: no root login, pubkey-only auth, 3 auth tries, no X11/TCP forwarding, short login grace time. Paired with `fail2ban` (`/etc/fail2ban/jail.local`, sshd jail: 5 attempts / 10 min → 1h ban, escalated to 2h for repeat sshd offenders).

**Safety check built in:** if the target user has no `~/.ssh/authorized_keys`, the script does **not** disable password authentication — it would lock you out with no way back in. It warns instead and leaves password auth enabled until you add a key:

```bash
ssh-copy-id yourname@this-host
sudo ./frost-security.sh --target /mnt   # re-run to flip PasswordAuthentication to no
```

## Tor (optional, off by default)

`--enable-tor` installs `tor`, `torsocks`, and `torbrowser-launcher`, and enables the Tor daemon. `torsocks nmap ...` routes a single command through Tor — but most of these tools weren't built with Tor in mind (DNS leaks, timing characteristics, and multi-connection behavior can all deanonymize you). Don't assume Tor alone makes scanning traffic anonymous.

## Files

```
frost-security.sh                  the installer script
security/
  wireguard/frost-wg0.conf.template
  openvpn/frost-client.ovpn.template
  ssh/99-frost-hardening.conf.template
  fail2ban/jail.local
```
