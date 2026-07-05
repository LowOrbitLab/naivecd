# naivecd

One-command NaiveProxy + Caddy installer for Debian/Ubuntu VPS.

## Features

- Downloads pinned prebuilt Caddy `klzgrad/forwardproxy` release `v2.11.2-naive` on amd64, with SHA256 verification before extraction
- Uses pinned source-build inputs when a build is required: Caddy `v2.11.2`, verified `go1.26.4` when Go is not already installed, `xcaddy@v0.4.6`, and `github.com/klzgrad/forwardproxy@v2.11.2-naive`
- Supports local static cover site or reverse-proxy cover site
- Automatically obtains a Let's Encrypt TLS certificate
- Generates NaiveProxy credentials, URI, QR code, CLI config, and sing-box outbound JSON
- Installs and manages `caddy.service` running as the dedicated `caddy` system user

## Requirements

- Debian 12 or Ubuntu 22.04+
- Public IPv4 VPS
- Domain A record pointing to the VPS
- Cloudflare proxy disabled / DNS-only
- Ports `80/tcp` and the selected HTTPS port open (`443/tcp` by default)
- Root access

## Install

Convenience install:

```bash
wget -qO- https://raw.githubusercontent.com/LowOrbitLab/naivecd/main/install.sh | sudo bash
```

The pipe-to-shell form is provided for convenience. For higher operational assurance, download `install.sh`, review it, and then run it with root privileges.

The installer asks for confirmation before making changes, even when values are
provided through environment variables.

## Supply-Chain Pins

The default amd64 prebuilt path downloads:

```text
https://github.com/klzgrad/forwardproxy/releases/download/v2.11.2-naive/caddy-forwardproxy-naive.tar.xz
```

The archive is verified before extraction and before any extracted Caddy binary is executed:

```text
19eccb7321dd877a5fb4a3dba6ef1b745185188b616c96cc6201f1a1fc0380a8
```

When source build is required, the installer uses an existing Go installation from `/usr/local/go` or `PATH` and logs its version. If Go must be installed, it downloads `go1.26.4` into a temporary directory and verifies the platform tarball before extraction:

| Artifact | SHA256 |
|---|---|
| `go1.26.4.linux-amd64.tar.gz` | `1153d3d50e0ac764b447adfe05c2bcf08e889d42a02e0fe0259bd47f6733ad7f` |
| `go1.26.4.linux-arm64.tar.gz` | `ef758ae7c6cf9267c9c0ef080b8965f453d89ab2d25d9eb22de4405925238768` |

Source builds install `github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.6` and build Caddy `v2.11.2` with `github.com/klzgrad/forwardproxy@v2.11.2-naive`.

## Cover Modes

Unauthenticated visits to your domain are served by a normal cover site.

### Local static site

Default mode. Caddy serves files from:

```text
/var/www/naive-cover
```

If `index.html` does not exist, the installer creates a Static Edge cover page.

### Reverse proxy

Caddy reverse-proxies unauthenticated visits to an external cover site.

Example:

```text
https://www.lovense.com
```

## Environment-driven Examples

These examples prefill installer inputs through environment variables, but the
installer still asks for confirmation before making changes. Set `NAIVE_PORT`
to choose the public HTTPS/NaiveProxy port; it defaults to `443`. Set
`NAIVE_CADDY_INSTALL=build` to force local `xcaddy` source build instead of the
default prebuilt amd64 binary.

Static cover:

```bash
wget -qO- https://raw.githubusercontent.com/LowOrbitLab/naivecd/main/install.sh | \
  sudo NAIVE_DOMAIN=proxy.example.com \
       NAIVE_COVER_MODE=static \
       NAIVE_PORT=443 \
       NAIVE_STATIC_ROOT=/var/www/naive-cover \
       bash
```

Reverse-proxy cover:

```bash
wget -qO- https://raw.githubusercontent.com/LowOrbitLab/naivecd/main/install.sh | \
  sudo NAIVE_DOMAIN=proxy.example.com \
       NAIVE_COVER_MODE=proxy \
       NAIVE_PORT=8443 \
       NAIVE_MASK_SITE=https://www.lovense.com \
       bash
```

## Output Files

| Path | Purpose |
|---|---|
| `/etc/caddy/Caddyfile` | Caddy + NaiveProxy config |
| `/etc/caddy/credentials.txt` | Credentials, selected port, and URI |
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
- the generated Static Edge `index.html`, only if it is unchanged
- empty managed directories, only when they were created by the installer

It preserves unmarked Caddy files, existing `/etc/caddy` contents, modified or pre-existing static site assets, Caddy TLS state under `/var/lib/caddy`, Go toolchains, DNS records, firewall rules, and the `caddy` system user/group.

## Notes

- Do not enable Cloudflare orange-cloud proxy for the NaiveProxy domain.
- Do not use sensitive paths as the static site root.
- This script does not configure firewall rules; open `80/tcp` plus the selected HTTPS port yourself.
- This script does not enable BBR or tune kernel networking.

## Sources

- <https://github.com/klzgrad/naiveproxy>
- <https://github.com/klzgrad/forwardproxy/tree/v2.11.2-naive>
- <https://caddyserver.com/>
