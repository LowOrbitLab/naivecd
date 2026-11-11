# naivecd

One-command NaiveProxy + Caddy installer for Debian/Ubuntu VPS.

## What It Does

- Installs Caddy with `github.com/klzgrad/forwardproxy@v2.11.7-naive2`
- Configures NaiveProxy over HTTPS with automatic Let's Encrypt certificates
- Creates a local Static Edge cover page or reverse-proxies a cover site
- Generates credentials plus Naive CLI and sing-box client config files
- Runs Caddy as the dedicated `caddy` system user

## Requirements

- Debian 12+ or Ubuntu 22.04+
- Root access
- Public IPv4 VPS
- Domain A record pointing to the VPS
- Cloudflare proxy disabled / DNS-only
- Ports `80/tcp` and selected HTTPS port open (`443/tcp` by default; `UDP` on the same port recommended for HTTP/3 QUIC)

## Install

```bash
wget -qO- https://raw.githubusercontent.com/LowOrbitLab/naivecd/main/install.sh | sudo bash
```

The installer asks for confirmation before making changes. For higher assurance,
download `install.sh`, review it, and run it with root privileges.

Optional environment variables:

- `NAIVE_DOMAIN`: proxy domain (e.g. `cdn.example.com`)
- `NAIVE_PORT`: HTTPS port (`1-65535`, except `80`; default `443`)
- `NAIVE_COVER_MODE`: `static` (default) or `proxy`
- `NAIVE_STATIC_ROOT`: directory for `static` cover mode (default `/var/www/naive-cover`)
- `NAIVE_MASK_SITE`: upstream `http(s)://` origin for `proxy` cover mode
- `NAIVE_CADDY_INSTALL`: `auto` (default), `prebuilt` (`amd64` only), or `build`

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
- The default amd64 path uses a pinned prebuilt Caddy archive with SHA256
  verification; other cases fall back to pinned source-build inputs (Caddy core,
  `klzgrad/forwardproxy` + upstream QUIC/idle-timeout patches, and Go toolchain).
