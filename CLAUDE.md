# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenClaw on Proxmox is a single-script deployment tool (`setup-openclaw-lxc.sh`) that automates creating a Proxmox LXC container with a fully configured OpenClaw AI assistant, LXQt desktop, Google Chrome, and VNC/noVNC remote access. It targets Proxmox VE 8.x+ hosts running as root.

## Architecture

The entire project is one Bash script (`setup-openclaw-lxc.sh`) with this flow:

1. **Pre-flight** — Verify Proxmox CLI tools (`pct`, `pvesh`, `pveam`), python3/openssl, root, amd64
2. **Settings** — Environment variables first, then prompts (`ask()`); all inputs validated
3. **Auto-detection** — VMID via `/cluster/nextid`; per-node enabled storage via `pvesh /nodes/<node>/storage` JSON + Python
4. **Template management** — Download newest Debian 13 template if missing
5. **Container creation** — Unprivileged (nesting) by default, `PRIVILEGED=1` opts out; DHCP; `--onboot`
6. **Provisioning payload** — A single strict (`set -euo pipefail`) script, embedded as the `'PROVISION'` heredoc, is pushed with `pct push` together with a 0600 env file carrying secrets, then run once inside the container
7. **Inside the container** (as the `openclaw` user where possible) — Node.js (NodeSource apt repo), Homebrew, OpenClaw, LXQt, TigerVNC, noVNC, Google Chrome, desktop config and shortcuts
8. **Systemd services** — `openclaw-gateway` (18789), `vncserver` (:1/5901), `novnc` (6080); all run as `openclaw`, loopback-only; `EXPOSE_LAN=1` exposes only noVNC, `--ssl-only` with a self-signed cert (the Control UI needs a secure context, so the gateway never leaves loopback)
9. **Verification** — Check services are active, print connection info
10. **Failure handling** — `cleanup` EXIT trap offers to destroy a half-built container

Key helpers: `ct_exec()` wraps `pct exec $VMID -- bash -c` for small host-driven checks; inside the provisioning script `quiet` (silent unless failing), `apt_install` and `as_user` (runuser as `openclaw`).

## Development Notes

- No build system or test suite; CI (`.github/workflows/lint.yml`) runs `bash -n` and ShellCheck on the host script AND on the embedded provisioning script (extracted between `cat > "$WORKDIR/provision.sh" <<'PROVISION'` and `PROVISION`). Run `shellcheck` locally before committing.
- The provisioning script is a quoted heredoc: no escaping needed inside it. Values come from the sourced env file (`printf %q` on the host). Files inside it that need variable expansion use an unquoted inner heredoc.
- Never put secrets on a command line; add them to `provision.env`.
- Chrome runs with its sandbox; extra flags go in `/etc/openclaw/chrome-flags` via the `/usr/local/bin/google-chrome` wrapper. We ship our own `.desktop` file rather than editing the package's.
- Homebrew is installed by the `openclaw` user; a temporary sudoers grant exists only during the installer.
- noVNC auto-scaling is set with `/usr/share/novnc/defaults.json` (dpkg-diverted so upgrades keep it), not by patching `ui.js`.
- Auth token: `openssl rand -hex 16`; VNC password: random 8 alphanumerics (VNC truncates at 8).
- Use Conventional Commits.

## Testing Changes

There is no automated test infrastructure. To test changes, run the script on a Proxmox host:

```bash
bash setup-openclaw-lxc.sh
```

Verify by checking: container creation, all three systemd services running, noVNC web access (via SSH tunnel, or HTTPS with `EXPOSE_LAN=1`), Chrome starting with its sandbox, and OpenClaw dashboard reachability.

## Shell Style

- Bash with `set -euo pipefail` (host script and provisioning script)
- Double-quoted variables throughout
- Heredocs for multi-line content (quoted `'EOF'` unless variable expansion is needed)
- Use `quiet` rather than `grep -v`/`tail` pipes to suppress noisy output, so failures are not masked
- Python3 one-liners for JSON parsing of Proxmox API output
