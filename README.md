# OpenClaw on Proxmox — One Script, Full AI Assistant

Deploy your own **[OpenClaw](https://openclaw.ai/) AI assistant** on any Proxmox server in minutes. One command, zero manual setup.

## Why use this?

- **Self-hosted AI assistant** — OpenClaw runs entirely on your hardware, under your control
- **One command to deploy** — no manual package installation, no config file editing, no guesswork
- **Full remote desktop** — access a graphical LXQt desktop from any browser via noVNC
- **Ready-to-use browser** — Google Chrome (sandboxed) as the default browser, ready for the OpenClaw browser extension
- **Lightweight, contained** — runs in an unprivileged LXC (not a full VM) as a regular user, so it's fast, resource-efficient and isolated from the host
- **Secure by default** — services listen on loopback only; opt in to LAN access with HTTPS for the desktop
- **Auto-starts on boot** — the container and all services (gateway, VNC, noVNC) start with the host
- **Onboarding made easy** — desktop shortcut walks you through OpenClaw setup step by step
- **Homebrew included** — install OpenClaw skills right away

## Quick Start

SSH into your Proxmox host and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/adadrag/Openclaw-Proxmox/main/setup-openclaw-lxc.sh)
```

That's it. The script will ask for a password, pick sensible defaults for everything else, and print your connection details when done.

Prefer to read it first? It's one file — download it (see below) and review it before running.

### Alternative install methods

**Download first, then run:**
```bash
wget -O setup-openclaw-lxc.sh https://raw.githubusercontent.com/adadrag/Openclaw-Proxmox/main/setup-openclaw-lxc.sh
chmod +x setup-openclaw-lxc.sh
./setup-openclaw-lxc.sh
```

**Clone the repo:**
```bash
git clone https://github.com/adadrag/Openclaw-Proxmox.git
cd Openclaw-Proxmox
chmod +x setup-openclaw-lxc.sh
./setup-openclaw-lxc.sh
```

## What you get

After the script finishes, you'll have a fully configured LXC container with:

By default the dashboard and the remote desktop listen on the container's **loopback only**. Reach them through an SSH tunnel from your computer:

```bash
ssh -L 6080:127.0.0.1:6080 -L 18789:127.0.0.1:18789 openclaw@<container-ip>
```

| What | Address (through the tunnel) |
|------|------------------------------|
| **Remote Desktop** | `http://localhost:6080/vnc.html` |
| **OpenClaw Dashboard** | `http://localhost:18789/` (or use the desktop shortcut, which fills in the token) |
| **SSH** | `ssh openclaw@<container-ip>` (root SSH login is not enabled; use `pct enter <VMID>` for a root shell) |

With `EXPOSE_LAN=1` the remote desktop is served directly at `https://<container-ip>:6080/vnc.html` (HTTPS only, self-signed certificate — accept the browser warning). The dashboard always stays on loopback: the OpenClaw Control UI needs a secure context (HTTPS or localhost), so open it from the desktop shortcut or through the tunnel.

The script prints the access details, the auth token and the generated VNC password at the end.

## Desktop Shortcuts

Once you open the remote desktop via noVNC, you'll find these shortcuts ready to go:

| Shortcut | What it does |
|----------|-------------|
| **Terminal** | Opens lxterminal |
| **Google Chrome** | The default browser |
| **OpenClaw Setup Wizard** | Opens the interactive onboarding wizard (`openclaw onboard`) to configure your channels, workspace, and skills |
| **OpenClaw Dashboard** | Opens Chrome with the dashboard URL and auth token pre-filled — no manual token entry needed |

## Requirements

- Proxmox VE 8.x+ on an amd64 host (Google Chrome is amd64-only); a recent `pve-container` (≥ 6.0.10 reported) is needed for Debian 13 containers — run `apt full-upgrade` if `pct create` rejects the template
- Root access on the Proxmox host
- Internet connectivity (for downloading packages)

## Configuration

The script prompts interactively (all optional except the password). Every option can also be preset with an environment variable for unattended runs:

```bash
CT_PASSWORD='s3cret' DISK_SIZE=64 MEMORY=8192 EXPOSE_LAN=1 ./setup-openclaw-lxc.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `CT_PASSWORD` | *(required)* | Password of the `openclaw` user (SSH / sudo) |
| `DISK_SIZE` | 32 | Root filesystem size in GB |
| `MEMORY` | 4096 | RAM in MB |
| `CORES` | 4 | CPU cores |
| `VNC_RES` | 1920x1080 | Remote desktop resolution |
| `EXPOSE_LAN` | 0 | `1` = serve noVNC on the LAN over HTTPS (the gateway stays on loopback) |
| `PRIVILEGED` | 0 | `1` = create a privileged container (not recommended) |
| `ONBOOT` | 1 | Start the container when the host boots |
| `VMID` | next free | Container ID |
| `CT_HOSTNAME` | openclaw | Container hostname |
| `BRIDGE` | vmbr0 | Network bridge (DHCP) |
| `TMPL_STORAGE` / `ROOT_STORAGE` | auto | Template / root disk storage |
| `OPENCLAW_VERSION` | latest | npm version of OpenClaw to install |
| `NODE_MAJOR` | 22 | Node.js major version |
| `HOMEBREW_INSTALL_REF` | HEAD | Git ref of the Homebrew installer |

The VNC password is generated randomly and printed at the end. VMID, storage and networking are auto-detected.

## What the script installs

All inside the container (nothing is installed on the Proxmox host):

- **Debian 13** LXC (unprivileged, nesting enabled)
- A regular **`openclaw`** user that runs everything — nothing runs as root
- **Node.js 22** (from the signed NodeSource apt repository) + **OpenClaw**
- **Homebrew** (for OpenClaw skills)
- **LXQt** desktop + **TigerVNC** + **noVNC**
- **Google Chrome** with its sandbox enabled; the OpenClaw browser extension is downloaded, and you load it in Chrome once (see below)
- **Noto Color Emoji** font (for proper terminal rendering)
- Three **systemd services**: `openclaw-gateway`, `vncserver`, `novnc`

## Container Management

```bash
pct enter <VMID>       # Shell into the container
pct stop <VMID>        # Stop the container
pct start <VMID>       # Start the container
pct status <VMID>      # Check container status
```

## Security model

- The container is **unprivileged**, and the gateway, desktop and Chrome run as the unprivileged `openclaw` user — an exploited browser or agent does not get root in the container, let alone on the host.
- Nothing is reachable from the network except SSH unless you set `EXPOSE_LAN=1`, which exposes only noVNC, over HTTPS. The gateway always stays on loopback.
- Secrets are handed to the container through a private file, not on command lines. The auth token and VNC password are printed once at the end; the dashboard shortcut file (readable only by `openclaw`) contains the token.
- `openclaw` has no sudo rights at all. Use `pct enter <VMID>` for administration.
- The remote desktop password is limited to 8 characters by the VNC protocol; treat noVNC as something to keep on loopback or a trusted network.
- The AI agent can still run commands as `openclaw` and browse the web on your behalf. Run it on a network segment you are comfortable with.

## Notes on the onboarding wizard

When you run the **OpenClaw Setup Wizard** from the desktop shortcut, you may see two messages that look like errors but are perfectly normal:

**"Gateway service install failed"** — The wizard tries to create its own systemd service for the gateway, but our script already set up `openclaw-gateway.service` and it's already running. This is safe to ignore.

**"SECURITY ERROR: ws:// to a non-loopback address"** — The gateway listens on loopback only, so you should not normally see this. If you reconfigure it to bind to the LAN, the token travels in clear text and the Control UI will not work over plain HTTP; use the SSH tunnel instead.

The wizard may also offer to change the gateway's bind address or token, or to install its own service. Decline those: the `openclaw-gateway` service and the dashboard shortcut depend on the settings the setup script wrote.

As long as you see your **channels connected**, a **Control UI URL**, and an **agent workspace** listed at the end of the wizard, everything worked.

## Troubleshooting

**Service not starting?**
```bash
pct exec <VMID> -- systemctl status openclaw-gateway
pct exec <VMID> -- systemctl status vncserver
pct exec <VMID> -- systemctl status novnc
```

**Chrome extension not loading?**
The extension is not activated automatically. Follow the instructions printed by `openclaw browser extension install` (the setup script saved that output to `~/openclaw-extension.txt` in the container, as `openclaw`); current OpenClaw releases install a native host and take the extension from the Chrome Web Store, and only need **Load unpacked** at `chrome://extensions` for a local build.

**Chrome won't start (sandbox error)?**
Chrome's sandbox needs user namespaces inside the container. As a last resort, run `echo --no-sandbox > /etc/openclaw/chrome-flags` as root in the container — this weakens isolation.

**Setup failed halfway?**
The script keeps the half-built container for inspection and offers to destroy it. To start over: `pct stop <VMID>; pct destroy <VMID> --purge`.

## License

MIT License. See [LICENSE](LICENSE) for details.
