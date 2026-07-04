# naivecd

One-command NaiveProxy + Caddy installer for Debian/Ubuntu VPS.

## Features

- Downloads prebuilt Caddy with `klzgrad/forwardproxy@naive` on amd64, with source-build fallback
- Supports local static cover site or reverse-proxy cover site
- Automatically obtains a Let's Encrypt TLS certificate
- Generates NaiveProxy credentials, URI, QR code, CLI config, and sing-box outbound JSON
- Installs and manages `caddy.service` running as the dedicated `caddy` system user

## Requirements

- Debian 12 or Ubuntu 22.04+
- Public IPv4 VPS
- Domain A record pointing to the VPS
- Cloudflare proxy disabled / DNS-only
- Ports `80/tcp` and `443/tcp` open
- Root access

## Install

```bash
wget -qO- https://raw.githubusercontent.com/LowOrbitLab/naivecd/main/install.sh | sudo bash
```

The installer asks for confirmation before making changes.

## Cover Modes

Unauthenticated visits to your domain are served by a normal cover site.

### Local static site

Default mode. Caddy serves files from:

```text
/var/www/naive-cover
```

If `index.html` does not exist, the installer creates a small placeholder page.

### Reverse proxy

Caddy reverse-proxies unauthenticated visits to an external cover site.

Example:

```text
https://www.lovense.com
```

## Non-interactive Examples

Set `NAIVE_CADDY_INSTALL=build` to force local `xcaddy` source build instead of the default prebuilt amd64 binary.

Static cover:

```bash
wget -qO- https://raw.githubusercontent.com/LowOrbitLab/naivecd/main/install.sh | \
  sudo NAIVE_DOMAIN=proxy.example.com \
       NAIVE_COVER_MODE=static \
       NAIVE_STATIC_ROOT=/var/www/naive-cover \
       bash
```

Reverse-proxy cover:

```bash
wget -qO- https://raw.githubusercontent.com/LowOrbitLab/naivecd/main/install.sh | \
  sudo NAIVE_DOMAIN=proxy.example.com \
       NAIVE_COVER_MODE=proxy \
       NAIVE_MASK_SITE=https://www.lovense.com \
       bash
```

## Output Files

| Path | Purpose |
|---|---|
| `/etc/caddy/Caddyfile` | Caddy + NaiveProxy config |
| `/etc/caddy/credentials.txt` | Credentials and URI |
| `/etc/caddy/naivecd-managed.env` | Managed-state record used for conservative uninstall |
| `/root/naive-client-config.json` | Naive CLI config |
| `/root/naive-singbox.json` | sing-box outbound JSON |
| `/var/www/naive-cover/index.html` | Static cover page, if static mode is used |

Caddy stores automatic TLS state and certificates under `/var/lib/caddy` and runs as `caddy:caddy`.

## Service Commands

```bash
systemctl status caddy
systemctl reload caddy
systemctl restart caddy
journalctl -u caddy -f
cat /etc/caddy/credentials.txt
```

When an existing installation is detected, the `Show client config` menu option is read-only. It prints saved credentials and client configuration files when present, then exits without changing packages, ports, files, services, or credentials.

## Uninstall

If Caddy is already installed, rerun the installer and choose the uninstall option from the existing-install menu.

Uninstall is conservative. The installer removes only resources recorded in `/etc/caddy/naivecd-managed.env` or carrying a naivecd marker, and it backs up managed files under `/root/naivecd-backups/<timestamp>/` before removal.

The uninstall option can remove managed:

- `caddy.service`
- `/usr/bin/caddy`
- `/etc/caddy/Caddyfile`
- `/etc/caddy/credentials.txt`
- `/root/naive-client-config.json`
- `/root/naive-singbox.json`
- the generated static placeholder `index.html`, only if it is unchanged
- empty managed directories, only when they were created by the installer

It preserves unmarked Caddy files, existing `/etc/caddy` contents, modified or pre-existing static site assets, Caddy TLS state under `/var/lib/caddy`, Go toolchains, DNS records, firewall rules, and the `caddy` system user/group.

## Notes

- Do not enable Cloudflare orange-cloud proxy for the NaiveProxy domain.
- Do not use sensitive paths as the static site root.
- This script does not configure firewall rules.
- This script does not enable BBR or tune kernel networking.

## Sources

- <https://github.com/klzgrad/naiveproxy>
- <https://github.com/klzgrad/forwardproxy/tree/naive>
- <https://caddyserver.com/>
