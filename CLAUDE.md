# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenClaw on Proxmox is a single-script deployment tool (`setup-openclaw-lxc.sh`) that automates creating a Proxmox LXC container with a fully configured OpenClaw AI assistant, LXQt desktop, Google Chrome, and VNC/noVNC remote access. It targets Proxmox VE 8.x+ hosts running as root.

## Architecture

The entire project is one Bash script (`setup-openclaw-lxc.sh`) with this flow:

1. **Pre-flight** — Verify Proxmox CLI tools (`pct`, `pvesh`, `pveam`), python3/openssl, root, amd64
2. **Settings** — Environment variables first, then prompts (`ask()`, `choose_option()` menus for bridge/storage); an "advanced options" gate asks the rarely used ones; all inputs validated (static network settings via a Python `ipaddress` check). Optional `GITHUB_SSH_USER`: `fetch_github_keys()` downloads `https://github.com/<user>.keys` on the host (curl, https only, size/count capped), keeps only lines matching a key-type regex that `ssh-keygen -l` accepts (rebuilt as `TYPE BLOB github:<user>`), and records fingerprints for the plan; interactive failures re-prompt, a preset username fails hard. `SSH_DISABLE_PASSWORD=1` (or the y/N follow-up) makes SSH key-only
3. **VMID & storage** — VMID prompt defaults to `/cluster/nextid` and is validated; `pick_storage()` lists per-node enabled storage (`pvesh /nodes/<node>/storage` JSON + Python) as a menu, or validates a preset `ROOT_STORAGE`/`TMPL_STORAGE`
4. **Template management** — Download newest Debian 13 template if missing
5. **Container creation** — Unprivileged (nesting) by default, `PRIVILEGED=1` opts out; networking from `BRIDGE`/`IP_ADDRESS`/`GATEWAY`/`NAMESERVER`/`VLAN_TAG`/`MTU` (DHCP or validated static IPv4), plus swap, timezone and `--onboot`
6. **Provisioning payload** — A single strict (`set -euo pipefail`) script, embedded as the `'PROVISION'` heredoc, is pushed with `pct push` together with a 0600 env file carrying secrets (and, when keys were imported, `/root/authorized_keys.github`, installed as `~openclaw/.ssh/authorized_keys` plus an optional `/etc/ssh/sshd_config.d/10-openclaw.conf`), then run once inside the container
6b. **Tailscale (optional, `ENABLE_TAILSCALE=1`)** — host grants `/dev/net/tun` (`pct set --dev0`, else lxc.* lines; provisioning falls back to userspace networking); the auth key travels as a 0600 file (`/root/ts-authkey`), never in the env file or a command line; inside, Tailscale is installed from its signed apt repo, `tailscale up --operator=openclaw`, noVNC is published with `tailscale serve --bg --https=8443`, and OpenClaw-managed Serve is enabled with `allowTailscale=false`. Results are reported to the host through `/etc/openclaw/status`
7. **Inside the container** (as the `openclaw` user where possible) — Node.js 24 (NodeSource apt repo; current OpenClaw needs Node ≥24.16 <25 or ≥26.1), Homebrew, OpenClaw, LXQt, TigerVNC, noVNC, Google Chrome, desktop config and shortcuts
8. **Systemd services** — `openclaw-gateway` (18789), `vncserver` (:1/5901), `novnc` (6080); all run as `openclaw`, loopback-only; `EXPOSE_LAN=1` exposes only noVNC, `--ssl-only` with a self-signed cert (the Control UI needs a secure context, so the gateway never leaves loopback)
9. **Verification** — `check()` probes (gateway HTTP, VNC port, noVNC, gateway restart count) plus service state and the provisioning status file `/etc/openclaw/status` (chrome sandbox probe, extension native-host registration); then print connection info
10. **Failure handling** — `cleanup` EXIT trap offers to destroy a half-built container

UX helpers (host script): `stage` (numbered `[n/6]` headings — keep `STEP_TOTAL` in sync when adding/removing stages), `info`/`ok`/`warn`/`err`, `kv` (aligned rows), and `summary` (final output; re-run without colors to write `/root/openclaw-lxc-<VMID>.txt`). Colors are off when stdout is not a TTY or `NO_COLOR` is set. The provisioning script counts its own unindented `step "..."` calls for its `[n/N]` progress; conditional steps are written indented and added to `STEP_TOTAL` explicitly.

Key helpers: `ct_exec()` wraps `pct exec $VMID -- bash -c` for small host-driven checks; inside the provisioning script `quiet` (silent unless failing), `apt_install` and `as_user` (runuser as `openclaw`).

## Development Notes

- No build system or test suite; CI (`.github/workflows/lint.yml`) runs `bash -n` and ShellCheck on the host script AND on the embedded provisioning script (extracted between `cat > "$WORKDIR/provision.sh" <<'PROVISION'` and `PROVISION`). Run `shellcheck` locally before committing.
- The provisioning script is a quoted heredoc: no escaping needed inside it. Values come from the sourced env file (`printf %q` on the host). Files inside it that need variable expansion use an unquoted inner heredoc.
- Never put secrets on a command line; add them to `provision.env`. Other payload files (e.g. `authorized_keys.github`) are written to `$WORKDIR` and pushed; add any new pushed file to both the host `cleanup` removal list and the provisioning script's EXIT trap.
- `WORKDIR` may already exist before provisioning (the GitHub key import creates it during the prompts); the `cleanup` trap removes it either way.
- The provisioning `[n/N]` counter counts unindented `step "..."` lines; conditional work goes inside an existing step with an indented `echo "      ..."` sub-line.
- Chrome runs with its sandbox; extra flags go in `/etc/openclaw/chrome-flags` via the `/usr/local/bin/google-chrome` wrapper. We ship our own `.desktop` file rather than editing the package's.
- OpenClaw compatibility notes: binary `openclaw`, config `~/.openclaw/openclaw.json`; npm ≥11.16 needs `--allow-scripts=openclaw`; the gateway unit follows OpenClaw's documented system-service template and sets `OPENCLAW_SERVICE_REPAIR_POLICY=external` so onboarding/doctor do not install a competing user unit; the browser extension comes from the Chrome Web Store on Linux.
- Homebrew is installed by the `openclaw` user; a temporary sudoers grant exists only during the installer.
- `/etc/sudoers.d/openclaw-gateway` (always installed, validated with `visudo -cf`) lets `openclaw` run only `systemctl restart openclaw-gateway` without a password. Keep it that narrow.
- `ENABLE_SUDO=1` (opt-in, default 0) adds `openclaw` to the `sudo` group; Debian's stock rule requires the user's password. Never add NOPASSWD: the agent runs as this user.
- noVNC auto-scaling is set with `/usr/share/novnc/defaults.json` (dpkg-diverted so upgrades keep it), not by patching `ui.js`.
- `htop jq ncdu mtr-tiny` are always installed; `EXTRA_PACKAGES` (env only, validated against a package-name regex, passed via the env file) adds more with an unquoted `apt_install`. Keep the default set small.
- Auth token: `openssl rand -hex 16`; VNC password: random 8 alphanumerics (VNC truncates at 8).
- Use Conventional Commits.

## Repository

`docs/` is the static GitHub Pages site (`index.html`, `assets/`, `robots.txt`, `sitemap.xml`, `404.html`, `.nojekyll`; no build step, no external dependencies), published from the `main` branch `/docs` folder at https://yorch.github.io/openclaw-proxmox/. When features or defaults change, update the site copy, the FAQ and its JSON-LD (`FAQPage`) together with the README; `assets/og-image.png` is the social card (1200x630).

The README is the project's front page: keep its tables (env vars, security model) in sync with the script. `assets/banner.svg` is the hand-written header image.

GitHub: `yorch/openclaw-proxmox` (a fork of `adadrag/Openclaw-Proxmox`). Keep README install URLs pointing at this repo. Commit messages follow Conventional Commits.

## Design decisions (and why) — do not undo without asking

Security posture (the agent runs as `openclaw` and runs commands and a browser, so it is treated as untrusted):
- Unprivileged LXC (nesting on), everything as the non-root `openclaw` user, Chrome keeps its sandbox (`--no-sandbox` only via `/etc/openclaw/chrome-flags` as a last resort). Root has **no password** and root SSH is not enabled; administer with `pct enter <VMID>` from the Proxmox host. Adding the GitHub SSH keys to root was considered and declined.
- Sudo: none by default. Two exceptions only: the narrow always-on rule (`/etc/sudoers.d/openclaw-gateway`, restart of `openclaw-gateway` only) and the opt-in `ENABLE_SUDO=1` (sudo group, password required). Never NOPASSWD beyond that one rule.
- Network: loopback by default. The gateway **never** leaves loopback (OpenClaw's Control UI needs a secure context, so a plain-HTTP LAN dashboard cannot work). `EXPOSE_LAN=1` exposes only noVNC, over HTTPS with `--ssl-only` and a self-signed certificate. VNC password is a separate random 8 characters (protocol limit), not the account password.
- Secrets travel as 0600 files via `pct push` (`provision.env`, `ts-authkey`, `authorized_keys.github`), never on command lines; they are removed by the provisioning EXIT trap and by the host `cleanup`.

Tailscale (all asked and decided with the owner): Serve only (no Funnel, no `--ssh`); off by default; login with an auth key (silent prompt or `TS_AUTHKEY`, passed as a file to `tailscale up --auth-key=file:`) or a printed login link; OpenClaw-managed Serve for the dashboard (`gateway.tailscale.mode serve`, needs `tailscale up --operator=openclaw`, which lets that user reconfigure Tailscale) with `gateway.auth.allowTailscale false`, so the token stays mandatory; noVNC published with `tailscale serve --bg --https=8443` (target `http://127.0.0.1:6080`, or `https+insecure://127.0.0.1:6080` when `EXPOSE_LAN=1` because noVNC then speaks TLS); `/dev/net/tun` via `pct set --dev0` then lxc.* lines, else userspace networking; the gateway unit is ordered after `tailscaled` only when Serve is up; failures in the Tailscale block must never abort the whole install (functions chained with `&&`).

Other decisions: the browser extension counts as installed when the native host is registered (`openclaw browser extension status --json`, `chrome` registration `owned`) because on Linux the extension itself comes from the Chrome Web Store and `extension install` can never finish unattended; template selection filters by `dpkg --print-architecture` (`arm64` sorts after `amd64`, an unfiltered newest pick once created an unstartable arm64 container); locale is generated with plain `locale-gen` and verified with `locale -a`; Node 24 because OpenClaw 2026.9+ requires >=24.16 <25 or >=26.1; Chrome is amd64-only so the installer refuses other architectures.

## Working conventions and pitfalls

- **No Proxmox host is available to the agent.** Real testing is done by the owner on their host (VMID 4002 in past runs), who pastes terminal output or screenshots. Everything not observed in those runs is "reviewed and linted, not run". Say so honestly; never claim a feature works on a host without evidence.
- **Review loop:** for larger features an Opus subagent (`Agent` with `model: opus`, read-only) does an adversarial review of the diff before pushing; fix its findings in a follow-up commit. When the owner says "ask me one at a time", use `AskUserQuestion` for each decision.
- **Git:** Conventional Commits; author comes from the global git config (Jorge Barnaby); end commits with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Push only when the owner says so (they usually answer "yes"/"push"). After pushing check CI (`gh run list`) and, for `docs/` changes, the Pages build (`gh api repos/yorch/openclaw-proxmox/pages/builds/latest`). `raw.githubusercontent.com` can serve a stale script for a few minutes after a push.
- **Do not `git add -A` blindly when agent worktrees exist**: `.claude/worktrees/` is gitignored now, but an embedded worktree was once committed by accident. Agents that edit the same files should use `isolation: worktree` and be cherry-picked (expect conflicts in the env-file, cleanup/trap file lists and summary blocks; keep both sides).
- **Local tooling (macOS dev machine):** `shellcheck` (brew). The system bash is 3.2, so tests that use associative arrays need `/opt/homebrew/bin/bash` (brew `bash`). Lint the embedded script with the CI `sed` extraction. Throwaway test scripts go in the session scratchpad, not the repo.
- **Website previews:** headless Chrome (`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --screenshot=...`). It enforces a minimum window width of about 500px, so check mobile layout by loading the page in a 390px iframe and reading `documentElement.scrollWidth` through `--dump-dom` (needs `--allow-file-access-from-files`); crop with `sips`. The OG image was rendered from an HTML file the same way.
- The website has no emojis (owner request); the only symbol left is the check mark in the installer-output mock.
- Keep README, `docs/index.html` (text, FAQ visible copy **and** the `FAQPage` JSON-LD) and this file in sync when behavior or defaults change.

## Status and open items (as of 2026-11-07)

Live and pushed: the installer with all features above, the README, the GitHub Pages site (https://yorch.github.io/openclaw-proxmox/, from `main` `/docs`), repo topics and homepage, CI lint. Google Search Console: a URL-prefix property for the Pages URL with the verification meta tag in `docs/index.html` (keep it); whether the owner finished verification and the sitemap submission is unknown. The latest commit (`efb9b29`, always-installed `htop jq ncdu mtr-tiny` plus `EXTRA_PACKAGES`) was made by another Claude session.

Verified by the owner's real runs: container creation, networking, provisioning of Node 24 + OpenClaw 2026.10.2, and the three services reported active. The Tailscale install and login also ran (the node joined the tailnet as `openclaw`), but publishing was skipped (see below). **Not seen running on a host:** the HTTP/port health probes added later, the GitHub SSH key import and `SSH_DISABLE_PASSWORD`, `ENABLE_SUDO`, the gateway-restart sudo rule (the owner was given a one-line command to add it to the existing container; whether they applied it is unknown), `EXTRA_PACKAGES`, and the headless Chrome sandbox probe result.

Open at the time of writing: the owner's Tailscale dashboard was not reachable. On their container `tailscale serve status` was empty and `gateway.tailscale.mode` unset, meaning the installer skipped publishing (likely tailnet HTTPS certificates/Serve not enabled, `CertDomains` empty — never confirmed). Manually publishing noVNC returned HTTP 502 until the target was changed to `https+insecure://127.0.0.1:6080` (they had installed with `EXPOSE_LAN=1`). Still to confirm: that `:8443` loads, that setting `gateway.tailscale.mode serve` + restarting publishes `:443`, and device pairing (`openclaw devices list` / `approve`). If the installer should detect missing tailnet HTTPS earlier and tell the user how to enable it, that is a possible improvement.

Unverified claims to re-check if they matter: Proxmox VE 8 support (PVE 9 is the target; Debian 13 containers need `pve-container` >= 6.0.10), `pct set --dev0` availability (assumed PVE 8.1+), `/healthz` on the loopback gateway, whether `openclaw onboard --skip-daemon` is accepted interactively, Chrome's sandbox in an unprivileged container, and that `tailscale set --operator` is exactly what OpenClaw-managed Serve needs.

Deferred ideas (researched, not built): an `update` subcommand with a release channel (stable/beta/extended-stable) since the gateway is installed by root npm and cannot self-update; unattended-upgrades; container tags/notes; post-install snapshot or vzdump job; pve-firewall rules; a `--config` file; optional non-interactive onboarding for one model provider key (needs an EnvironmentFile and may need plugins); `browser.executablePath`; `openclaw backup enable`; Docker sandboxing (fragile in an unprivileged LXC), GPU passthrough, Funnel, channel setup, Caddy (rejected as redundant with Tailscale Serve).

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
