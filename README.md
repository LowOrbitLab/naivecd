# naivecd

One-command NaiveProxy + Caddy installer for Debian/Ubuntu VPS.

## What It Does

- Installs Caddy with `github.com/klzgrad/forwardproxy@v2.11.2-naive`
- Configures NaiveProxy over HTTPS with automatic Let's Encrypt certificates
- Creates a local Static Edge cover page or reverse-proxies a cover site
- Generates credentials plus Naive CLI and sing-box client config files
- Runs Caddy as the dedicated `caddy` system user

## Requirements

- Debian 12 or Ubuntu 22.04+
- Root access
- Public IPv4 VPS
- Domain A record pointing to the VPS
- Cloudflare proxy disabled / DNS-only
- Ports `80/tcp` and selected HTTPS port open (`443/tcp` by default)

## Install

```bash
wget -qO- https://raw.githubusercontent.com/LowOrbitLab/naivecd/main/install.sh | sudo bash
```

The installer asks for confirmation before making changes. For higher assurance,
download `install.sh`, review it, and run it with root privileges.

## Output Files

- `/etc/caddy/Caddyfile`
- `/etc/caddy/credentials.txt`
- `/etc/caddy/naivecd-managed.env`
- `/root/naive-client-config.json`
- `/root/naive-singbox.json`
- `/var/www/naive-cover/index.html` when static cover mode is used

Caddy stores TLS state under `/var/lib/caddy`.

## Existing Install / Uninstall

Rerun the installer when Caddy already exists. It will offer:

- reinstall NaiveProxy
- reconfigure
- show saved client config
- uninstall

Uninstall is conservative: it removes managed files only when they are recorded
in `/etc/caddy/naivecd-managed.env` or carry a naivecd marker. Backups are saved
under `/root/naivecd-backups/<timestamp>/`.

## Notes

- Do not enable Cloudflare orange-cloud proxy for the NaiveProxy domain.
- Do not use sensitive paths as the static site root.
- This script does not configure firewall rules.
- This script does not enable BBR or tune kernel networking.
- The default amd64 path uses a pinned prebuilt Caddy archive with SHA256
  verification; other cases fall back to pinned source-build inputs.
