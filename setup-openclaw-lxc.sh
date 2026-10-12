#!/usr/bin/env bash
#
# setup-openclaw-lxc.sh — Automated OpenClaw AI assistant setup in a Proxmox LXC container
#
# Run this script directly on the Proxmox host.
# It creates a Debian 13 LXC, installs OpenClaw + LXQt desktop + Google Chrome + VNC/noVNC,
# and prints connection info when done.
#
# Every setting can be preset through the environment for unattended runs, e.g.:
#   CT_PASSWORD='s3cret' DISK_SIZE=64 MEMORY=8192 CORES=6 ./setup-openclaw-lxc.sh
# Supported: CT_PASSWORD DISK_SIZE MEMORY CORES VNC_RES VMID CT_HOSTNAME BRIDGE
#            TMPL_STORAGE ROOT_STORAGE ONBOOT PRIVILEGED NODE_MAJOR OPENCLAW_VERSION
#            HOMEBREW_INSTALL_REF EXPOSE_LAN
#

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fatal() { err "$@"; exit 1; }

# ─── Cleanup on failure ──────────────────────────────────────────────────────
VMID="${VMID:-}"
CT_CREATED=0
WORKDIR=""

cleanup() {
    local rc=$?
    trap - EXIT
    [[ -z "$WORKDIR" ]] || rm -rf "$WORKDIR"
    if (( rc != 0 && CT_CREATED )); then
        # Never leave the secrets file behind in a half-provisioned container
        pct exec "$VMID" -- rm -f /root/provision.env /root/provision.sh >/dev/null 2>&1 || true
        err "Setup failed. Container $VMID was left in place for inspection."
        err "  Inspect:  pct enter $VMID"
        err "  Remove:   pct stop $VMID; pct destroy $VMID --purge"
        if [[ -t 0 && -t 1 ]]; then
            local answer=""
            read -rp "Destroy container $VMID now? [y/N]: " answer || true
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                pct stop "$VMID" >/dev/null 2>&1 || true
                if pct destroy "$VMID" --purge >/dev/null 2>&1; then
                    info "Container $VMID destroyed."
                else
                    err "Could not destroy container $VMID."
                fi
            fi
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ─── Pre-flight checks ───────────────────────────────────────────────────────
command -v pct  >/dev/null 2>&1 || fatal "pct not found — this script must run on a Proxmox host."
command -v pvesh >/dev/null 2>&1 || fatal "pvesh not found — this script must run on a Proxmox host."
command -v pveam >/dev/null 2>&1 || fatal "pveam not found — this script must run on a Proxmox host."
command -v python3 >/dev/null 2>&1 || fatal "python3 not found (needed to parse Proxmox API output)."
command -v openssl >/dev/null 2>&1 || fatal "openssl not found."
[[ $(id -u) -eq 0 ]] || fatal "This script must be run as root."
[[ "$(dpkg --print-architecture)" == "amd64" ]] \
    || fatal "Only amd64 hosts are supported (Google Chrome is installed from the amd64 .deb)."

# ─── Settings (environment first, then prompts) ──────────────────────────────
# ask VAR "Prompt" DEFAULT — keep a preset value, else prompt on a TTY, else use the default.
ask() {
    local var="$1" prompt="$2" default="$3" reply=""
    [[ -z "${!var:-}" ]] || return 0
    if [[ -t 0 ]]; then
        read -rp "$prompt [$default]: " reply
    fi
    printf -v "$var" '%s' "${reply:-$default}"
}

require_int() { # require_int NAME MIN MAX
    local name="$1" min="$2" max="$3" value="${!1}"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || (( 10#$value < min || 10#$value > max )); then
        fatal "$name must be a whole number between $min and $max (got '$value')."
    fi
}

echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     OpenClaw LXC Setup for Proxmox               ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
echo

if [[ -z "${CT_PASSWORD:-}" ]]; then
    [[ -t 0 ]] || fatal "No terminal available — set CT_PASSWORD in the environment."
    read -rp "Password for the openclaw user (also VNC): " -s CT_PASSWORD
    echo
    read -rp "Confirm password: " -s CT_PASSWORD_CONFIRM
    echo
    [[ "$CT_PASSWORD" == "$CT_PASSWORD_CONFIRM" ]] || fatal "Passwords do not match."
fi
[[ -n "$CT_PASSWORD" ]] || fatal "Password cannot be empty."
[[ "$CT_PASSWORD" != *$'\n'* ]] || fatal "Password cannot contain newlines."

ask DISK_SIZE "Disk size in GB"  32
ask MEMORY    "Memory in MB"     4096
ask CORES     "CPU cores"        4
ask VNC_RES   "VNC resolution"   1920x1080
ask EXPOSE_LAN "Expose noVNC on the LAN over HTTPS? 1=yes 0=no (loopback only, use an SSH tunnel)" 0
CT_HOSTNAME="${CT_HOSTNAME:-openclaw}"
BRIDGE="${BRIDGE:-vmbr0}"
ONBOOT="${ONBOOT:-1}"
# Unprivileged by default; PRIVILEGED=1 is an explicit opt-in
[[ "${PRIVILEGED:-0}" =~ ^[01]$ ]] || fatal "PRIVILEGED must be 0 or 1."
UNPRIVILEGED=$(( 1 - ${PRIVILEGED:-0} ))

require_int DISK_SIZE 4 100000
require_int MEMORY 1024 1000000
require_int CORES 1 512
DISK_SIZE=$((10#$DISK_SIZE)); MEMORY=$((10#$MEMORY)); CORES=$((10#$CORES))
[[ "$VNC_RES" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]] || fatal "VNC resolution must look like 1920x1080 (got '$VNC_RES')."
[[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || fatal "Invalid hostname '$CT_HOSTNAME'."
[[ "$BRIDGE" =~ ^[a-zA-Z0-9_.-]+$ ]] || fatal "Invalid bridge name '$BRIDGE'."
[[ "$ONBOOT" =~ ^[01]$ ]] || fatal "ONBOOT must be 0 or 1."
[[ "$EXPOSE_LAN" =~ ^[01]$ ]] || fatal "EXPOSE_LAN must be 0 or 1."
ip link show "$BRIDGE" >/dev/null 2>&1 || fatal "Bridge '$BRIDGE' does not exist on this host."

echo

# ─── Auto-detect next VMID ───────────────────────────────────────────────────
info "Selecting VMID..."
if [[ -z "$VMID" ]]; then
    VMID=$(pvesh get /cluster/nextid 2>/dev/null) || fatal "Could not get the next free VMID from the cluster."
fi
[[ "$VMID" =~ ^[0-9]+$ ]] || fatal "Invalid VMID '$VMID'."
pvesh get /cluster/nextid --vmid "$VMID" >/dev/null 2>&1 || fatal "VMID $VMID is already in use."
ok "Will use VMID: $VMID"

# ─── Auto-detect storage ─────────────────────────────────────────────────────
info "Detecting storage..."
NODE=$(hostname -s)

# Enabled storages on this node that can hold the given content type (JSON)
node_storage() {
    pvesh get "/nodes/$NODE/storage" --content "$1" --enabled 1 --output-format json 2>/dev/null
}

# Template storage: prefer "local", else the first one that accepts vztmpl
TMPL_STORAGE="${TMPL_STORAGE:-$(node_storage vztmpl | python3 -c '
import json, sys
names = [s["storage"] for s in json.load(sys.stdin)]
print("local" if "local" in names else (names[0] if names else ""))
' 2>/dev/null || true)}"
[[ -n "$TMPL_STORAGE" ]] || fatal "No enabled storage on node '$NODE' accepts container templates (vztmpl)."

# Rootfs storage: prefer local-lvm, else the rootdir storage with the most free space
ROOT_STORAGE="${ROOT_STORAGE:-$(node_storage rootdir | python3 -c '
import json, sys
stores = json.load(sys.stdin)
names = [s["storage"] for s in stores]
if "local-lvm" in names:
    print("local-lvm")
elif stores:
    print(max(stores, key=lambda s: s.get("avail", 0))["storage"])
' 2>/dev/null || true)}"
[[ -n "$ROOT_STORAGE" ]] || fatal "No enabled storage on node '$NODE' accepts container root disks (rootdir)."

ok "Template storage: $TMPL_STORAGE"
ok "Rootfs storage:   $ROOT_STORAGE"

# Debian 13 templates need a recent pve-container (reported fixed in 6.0.10 on PVE 9)
PVE_CONTAINER_VERSION=$(dpkg-query -W -f='${Version}' pve-container 2>/dev/null || true)
if [[ -n "$PVE_CONTAINER_VERSION" ]] && dpkg --compare-versions "$PVE_CONTAINER_VERSION" lt 6.0.10; then
    warn "pve-container $PVE_CONTAINER_VERSION may not support Debian 13 containers — if 'pct create' fails, run 'apt update && apt full-upgrade'."
fi

# ─── Download Debian 13 template ─────────────────────────────────────────────
info "Checking for Debian 13 template..."
pveam update >/dev/null 2>&1 || warn "pveam update failed — using the cached template index."

# Newest Debian 13 template in the index (version sort, not index order)
TEMPLATE=$(pveam available --section system 2>/dev/null | grep -oP 'debian-13-standard_\S+' | sort -V | tail -n 1 || true)
[[ -n "$TEMPLATE" ]] || fatal "Could not find a Debian 13 template. Check 'pveam available'."

TEMPLATE_LIST=$(pveam list "$TMPL_STORAGE" 2>/dev/null || true)
if [[ "$TEMPLATE_LIST" == *"$TEMPLATE"* ]]; then
    ok "Template already downloaded: $TEMPLATE"
else
    info "Downloading $TEMPLATE to $TMPL_STORAGE..."
    pveam download "$TMPL_STORAGE" "$TEMPLATE"
    ok "Template downloaded."
fi

# ─── Create the LXC container ────────────────────────────────────────────────
info "Creating LXC container $VMID..."
pct create "$VMID" "${TMPL_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --rootfs "${ROOT_STORAGE}:${DISK_SIZE}" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" \
    --features nesting=1 \
    --onboot "$ONBOOT" \
    --start 0
CT_CREATED=1
ok "Container $VMID created."

info "Starting container $VMID..."
pct start "$VMID"
ok "Container started."

# Helper: run a command inside the container
ct_exec() {
    pct exec "$VMID" -- bash -c "$1"
}

# First IPv4 address of the container (ignores IPv6 SLAAC addresses)
ct_ip() {
    ct_exec "ip -4 -o addr show dev eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n 1" || true
}

info "Waiting for container to boot..."
for _ in $(seq 1 30); do
    ct_exec "true" >/dev/null 2>&1 && break
    sleep 1
done
ct_exec "true" >/dev/null 2>&1 || fatal "Container did not become reachable."

# ─── Wait for network ────────────────────────────────────────────────────────
info "Waiting for DHCP lease (up to 60s)..."
CT_IP=""
for _ in $(seq 1 60); do
    CT_IP=$(ct_ip)
    [[ -n "$CT_IP" ]] && break
    sleep 1
done
[[ -n "$CT_IP" ]] || fatal "Container got no IP address. Check that bridge '$BRIDGE' has a DHCP server."
ok "Container IP: $CT_IP"

info "Checking DNS and internet access from the container..."
for _ in $(seq 1 30); do
    ct_exec "getent hosts deb.debian.org >/dev/null" 2>/dev/null && break
    sleep 1
done
ct_exec "getent hosts deb.debian.org >/dev/null" 2>/dev/null \
    || fatal "Container cannot resolve deb.debian.org — check DNS and the network configuration."
ok "Container has network access."

# ─── Build the in-container provisioning payload ─────────────────────────────
# Everything inside the container runs as ONE strict script (set -euo pipefail) that is
# copied in with `pct push`. Secrets travel in a 0600 env file, never on a command line.
AUTH_TOKEN=$(openssl rand -hex 16)
# VNC only uses the first 8 characters of its password, so generate exactly 8 random ones
VNC_PASSWORD=$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(8)))')
CT_USER="openclaw"

WORKDIR=$(mktemp -d)
chmod 700 "$WORKDIR"

{
    printf 'CT_USER=%q\n'              "$CT_USER"
    printf 'CT_PASSWORD=%q\n'          "$CT_PASSWORD"
    printf 'AUTH_TOKEN=%q\n'           "$AUTH_TOKEN"
    printf 'VNC_PASSWORD=%q\n'         "$VNC_PASSWORD"
    printf 'EXPOSE_LAN=%q\n'           "$EXPOSE_LAN"
    printf 'CT_HOSTNAME=%q\n'          "$CT_HOSTNAME"
    printf 'VNC_RES=%q\n'              "$VNC_RES"
    printf 'NODE_MAJOR=%q\n'           "${NODE_MAJOR:-22}"
    printf 'OPENCLAW_VERSION=%q\n'     "${OPENCLAW_VERSION:-latest}"
    printf 'HOMEBREW_INSTALL_REF=%q\n' "${HOMEBREW_INSTALL_REF:-HEAD}"
} > "$WORKDIR/provision.env"

cat > "$WORKDIR/provision.sh" <<'PROVISION'
#!/usr/bin/env bash
# Runs inside the container as root. Any failing command aborts the whole setup.
set -euo pipefail

# shellcheck disable=SC1091
source /root/provision.env
trap 'rm -f /root/provision.env /root/provision.sh /etc/sudoers.d/openclaw-provision' EXIT

export DEBIAN_FRONTEND=noninteractive
USER_HOME="/home/${CT_USER}"
cd /   # pct exec inherits the host's cwd, which the unprivileged user cannot read

step() { echo "  → $*"; }

# Run a command silently; replay its output only if it fails.
quiet() {
    local log
    log=$(mktemp)
    if ! "$@" >"$log" 2>&1; then
        echo "Command failed: $*" >&2
        tail -n 40 "$log" >&2
        rm -f "$log"
        return 1
    fi
    rm -f "$log"
}
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt_install() { quiet apt-get install -y "${APT_OPTS[@]}" "$@"; }
as_user() { runuser -u "$CT_USER" -- env HOME="$USER_HOME" "$@"; }

# ── Base system ──────────────────────────────────────────────────────────────
step "Updating packages and installing prerequisites"
quiet apt-get update
apt_install locales
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
quiet locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
quiet apt-get upgrade -y "${APT_OPTS[@]}"
apt_install curl ca-certificates gnupg git sudo openssh-server

# ── Unprivileged login user (runs the desktop, Chrome and the gateway) ───────
step "Creating user ${CT_USER}"
id "$CT_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$CT_USER"
chpasswd <<<"${CT_USER}:${CT_PASSWORD}"
systemctl enable --now ssh >/dev/null 2>&1

# ── Node.js (signed NodeSource apt repository, no piped installer) ───────────
step "Installing Node.js ${NODE_MAJOR}"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
quiet apt-get update
apt_install nodejs
[[ "$(node -p 'process.versions.node.split(".")[0]')" == "$NODE_MAJOR" ]] \
    || { echo "Node.js ${NODE_MAJOR} was not installed" >&2; exit 1; }

# ── Homebrew (needed by OpenClaw skills; installed as the login user) ────────
step "Installing Homebrew"
apt_install build-essential procps file
# Homebrew's installer needs sudo once; the grant is removed again right after.
echo "${CT_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/openclaw-provision
chmod 440 /etc/sudoers.d/openclaw-provision
curl -fsSL "https://raw.githubusercontent.com/Homebrew/install/${HOMEBREW_INSTALL_REF}/install.sh" -o /tmp/brew-install.sh
chmod 755 /tmp/brew-install.sh
quiet as_user env NONINTERACTIVE=1 /bin/bash /tmp/brew-install.sh
rm -f /tmp/brew-install.sh /etc/sudoers.d/openclaw-provision
BREW=/home/linuxbrew/.linuxbrew/bin/brew
[[ -x "$BREW" ]] || { echo "Homebrew was not installed" >&2; exit 1; }
grep -qs 'brew shellenv' "$USER_HOME/.bashrc" \
    || echo "eval \"\$($BREW shellenv)\"" >> "$USER_HOME/.bashrc"

# ── OpenClaw ─────────────────────────────────────────────────────────────────
step "Installing OpenClaw (${OPENCLAW_VERSION})"
quiet npm install -g "openclaw@${OPENCLAW_VERSION}"
OPENCLAW_BIN=$(command -v openclaw) || { echo "openclaw binary not found after install" >&2; exit 1; }

# ── Desktop, VNC, noVNC ──────────────────────────────────────────────────────
step "Installing LXQt, TigerVNC and noVNC (this takes a few minutes)"
apt_install lxqt openbox lxterminal tigervnc-standalone-server novnc websockify dbus-x11 \
    fonts-noto-color-emoji xdg-utils
WEBSOCKIFY_BIN=$(command -v websockify) || { echo "websockify not found after install" >&2; exit 1; }

# ── Google Chrome ────────────────────────────────────────────────────────────
step "Installing Google Chrome"
curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb
apt_install /tmp/chrome.deb
rm -f /tmp/chrome.deb

# ── OpenClaw configuration ───────────────────────────────────────────────────
step "Configuring OpenClaw"
as_user openclaw config set gateway.mode local
# The Control UI needs a secure context (HTTPS or localhost) for its device identity, so
# the gateway stays on loopback even with EXPOSE_LAN=1; reach it from the desktop or a tunnel.
GATEWAY_BIND=loopback
as_user openclaw config set gateway.bind "$GATEWAY_BIND"
as_user openclaw config set gateway.auth.token "$AUTH_TOKEN"

step "Installing the OpenClaw browser extension"
if as_user openclaw browser extension install > "$USER_HOME/openclaw-extension.txt" 2>&1; then
    chown "$CT_USER:$CT_USER" "$USER_HOME/openclaw-extension.txt"
else
    echo "WARNING: 'openclaw browser extension install' failed; see ${USER_HOME}/openclaw-extension.txt" >&2
fi

# ── VNC ──────────────────────────────────────────────────────────────────────
step "Configuring VNC"
install -d -o "$CT_USER" -g "$CT_USER" -m 0700 "$USER_HOME/.config" "$USER_HOME/.config/tigervnc"
printf '%s\n' "$VNC_PASSWORD" | vncpasswd -f > "$USER_HOME/.config/tigervnc/passwd"
chmod 600 "$USER_HOME/.config/tigervnc/passwd"

cat > "$USER_HOME/.config/tigervnc/xstartup" <<'XSTARTUP'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session startlxqt
XSTARTUP
chmod +x "$USER_HOME/.config/tigervnc/xstartup"

# noVNC: scale the remote desktop to the browser window by default. defaults.json is
# read by noVNC at runtime, so unlike patching ui.js it survives package upgrades.
# The package owns defaults.json, so divert it to keep our copy across upgrades.
if [[ -z "$(dpkg-divert --list /usr/share/novnc/defaults.json)" ]]; then
    dpkg-divert --local --rename --add /usr/share/novnc/defaults.json >/dev/null
fi
echo '{ "resize": "scale" }' > /usr/share/novnc/defaults.json

# ── noVNC listener: loopback-only unless exposure was requested, then HTTPS ──
if [[ "$EXPOSE_LAN" == "1" ]]; then
    step "Generating a self-signed certificate for noVNC"
    install -d /etc/openclaw
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=${CT_HOSTNAME}" \
        -keyout /etc/openclaw/novnc.key -out /etc/openclaw/novnc.crt 2>/dev/null
    chown "$CT_USER:$CT_USER" /etc/openclaw/novnc.key /etc/openclaw/novnc.crt
    chmod 600 /etc/openclaw/novnc.key
    NOVNC_ARGS="--ssl-only --cert=/etc/openclaw/novnc.crt --key=/etc/openclaw/novnc.key 0.0.0.0:6080"
else
    NOVNC_ARGS="127.0.0.1:6080"
fi

# ── Desktop configuration ────────────────────────────────────────────────────
step "Configuring the desktop"
install -d "$USER_HOME/.config/lxterminal" "$USER_HOME/.config/autostart" \
    "$USER_HOME/.config/lxqt" "$USER_HOME/Desktop"

cat > "$USER_HOME/.config/lxterminal/lxterminal.conf" <<'CONF'
[general]
fontname=Monospace 12
bgcolor=#1e1e2e
fgcolor=#cdd6f4
palette_color_0=#45475a
palette_color_1=#f38ba8
palette_color_2=#a6e3a1
palette_color_3=#f9e2af
palette_color_4=#89b4fa
palette_color_5=#f5c2e7
palette_color_6=#94e2d5
palette_color_7=#bac2de
palette_color_8=#585b70
palette_color_9=#f38ba8
palette_color_10=#a6e3a1
palette_color_11=#f9e2af
palette_color_12=#89b4fa
palette_color_13=#f5c2e7
palette_color_14=#94e2d5
palette_color_15=#a6adc8
scrollback=10000
CONF

# LXC has no power hardware and a VNC session needs no screen saver
cat > "$USER_HOME/.config/autostart/lxqt-powermanagement.desktop" <<'NOAUTO'
[Desktop Entry]
Type=Application
Name=LXQt Power Management
Hidden=true
NOAUTO
cat > "$USER_HOME/.config/autostart/lxqt-xscreensaver-autostart.desktop" <<'NOAUTO'
[Desktop Entry]
Type=Application
Name=LXQt Screen Saver
Hidden=true
NOAUTO

cat > "$USER_HOME/.config/lxqt/session.conf" <<'CONF'
[General]
__userfile__=true

[Environment]
TERM=xterm-256color

[Preferred Applications]
terminal_emulator=lxterminal
CONF

# ── Google Chrome as the default browser ─────────────────────────────────────
# Chrome runs as the unprivileged user with its sandbox ENABLED. If the sandbox cannot
# start in your environment, put "--no-sandbox" in /etc/openclaw/chrome-flags (not advised).
step "Configuring Google Chrome"
install -d /etc/openclaw
touch /etc/openclaw/chrome-flags

cat > /usr/local/bin/google-chrome <<'WRAPPER'
#!/bin/bash
# Launches Chrome with any extra flags listed (one line) in /etc/openclaw/chrome-flags
flags=()
if [[ -r /etc/openclaw/chrome-flags ]]; then
    read -r -a flags < /etc/openclaw/chrome-flags || true
fi
exec /usr/bin/google-chrome-stable "${flags[@]}" "$@"
WRAPPER
chmod 755 /usr/local/bin/google-chrome

# Own .desktop entry instead of editing the package's file, so upgrades cannot undo it
install -d /usr/local/share/applications
cat > /usr/local/share/applications/openclaw-chrome.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
Comment=Access the Internet
Exec=/usr/local/bin/google-chrome %U
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
DESKTOP
cp /usr/local/share/applications/openclaw-chrome.desktop "$USER_HOME/Desktop/google-chrome.desktop"

update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/local/bin/google-chrome 250
update-alternatives --set x-www-browser /usr/local/bin/google-chrome
update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/local/bin/google-chrome 250
update-alternatives --set gnome-www-browser /usr/local/bin/google-chrome
for mime in x-scheme-handler/http x-scheme-handler/https text/html; do
    as_user xdg-mime default openclaw-chrome.desktop "$mime"
done

# ── Desktop shortcuts ────────────────────────────────────────────────────────
step "Creating desktop shortcuts"
cat > "$USER_HOME/Desktop/terminal.desktop" <<'SHORTCUT'
[Desktop Entry]
Version=1.0
Type=Application
Name=Terminal
Comment=Open a terminal
Exec=lxterminal
Icon=utilities-terminal
Terminal=false
Categories=System;TerminalEmulator;
StartupNotify=true
SHORTCUT

cat > "$USER_HOME/Desktop/openclaw-onboard.desktop" <<'SHORTCUT'
[Desktop Entry]
Version=1.0
Type=Application
Name=OpenClaw Setup Wizard
Comment=Run the OpenClaw onboarding wizard to configure your AI assistant
Exec=lxterminal --title='OpenClaw Onboarding' -e sh -c 'openclaw onboard; exec bash'
Icon=utilities-terminal
Terminal=false
Categories=Utility;
StartupNotify=true
SHORTCUT

# Opens the dashboard with the token pre-filled; the file is private to the user
cat > "$USER_HOME/Desktop/openclaw-dashboard.desktop" <<SHORTCUT
[Desktop Entry]
Version=1.0
Type=Application
Name=OpenClaw Dashboard
Comment=Open the OpenClaw Control UI in Google Chrome
Exec=/usr/local/bin/google-chrome "http://127.0.0.1:18789/#token=${AUTH_TOKEN}"
Icon=web-browser
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
SHORTCUT

chmod 755 "$USER_HOME"/Desktop/*.desktop
chmod 700 "$USER_HOME/Desktop/openclaw-dashboard.desktop"
chown -R "$CT_USER:$CT_USER" "$USER_HOME"

# ── systemd services ─────────────────────────────────────────────────────────
step "Creating systemd services"
cat > /etc/systemd/system/openclaw-gateway.service <<SVC
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CT_USER}
Environment=HOME=${USER_HOME}
Environment=NODE_ENV=production
WorkingDirectory=${USER_HOME}
ExecStart=${OPENCLAW_BIN} gateway run --bind ${GATEWAY_BIND} --auth token
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/vncserver.service <<SVC
[Unit]
Description=TigerVNC Server
After=network.target

[Service]
Type=forking
User=${CT_USER}
Environment=HOME=${USER_HOME}
ExecStartPre=-/usr/bin/vncserver -kill :1
ExecStart=/usr/bin/vncserver :1 -geometry ${VNC_RES} -depth 24 -localhost yes
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/novnc.service <<SVC
[Unit]
Description=noVNC WebSocket Proxy
After=vncserver.service
Requires=vncserver.service

[Service]
Type=simple
User=${CT_USER}
ExecStart=${WEBSOCKIFY_BIN} --web=/usr/share/novnc/ ${NOVNC_ARGS} 127.0.0.1:5901
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable openclaw-gateway.service vncserver.service novnc.service >/dev/null 2>&1
# A service that fails to start is reported by the host's verification step, not fatal here
systemctl start openclaw-gateway.service vncserver.service novnc.service \
    || echo "WARNING: at least one service failed to start (see systemctl status)" >&2
PROVISION

# ─── Provision the container ─────────────────────────────────────────────────
info "Provisioning the container (several minutes — packages, desktop, Chrome)..."
pct push "$VMID" "$WORKDIR/provision.env" /root/provision.env --perms 0600
pct push "$VMID" "$WORKDIR/provision.sh"  /root/provision.sh  --perms 0700
pct exec "$VMID" -- bash /root/provision.sh
ok "Container provisioned."

sleep 3

# ─── Verify services ─────────────────────────────────────────────────────────
info "Verifying services..."
for svc in openclaw-gateway vncserver novnc; do
    if ct_exec "systemctl is-active --quiet $svc"; then
        ok "$svc is running."
    else
        warn "$svc failed to start. Check with: pct exec $VMID -- systemctl status $svc"
    fi
done

# Re-detect IP in case it changed
CT_IP=$(ct_ip)
CT_IP="${CT_IP:-unknown}"
EXT_INFO=$(ct_exec "cat /home/${CT_USER}/openclaw-extension.txt 2>/dev/null | tail -n 5" || true)

# ─── Print connection info ────────────────────────────────────────────────────
echo
echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           OpenClaw LXC Setup Complete!            ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
echo
echo -e "  ${BOLD}Container ID:${NC}  $VMID"
echo -e "  ${BOLD}Container IP:${NC}  $CT_IP"
echo -e "  ${BOLD}Login user:${NC}    $CT_USER (SSH password: the one you entered; no sudo — use pct enter for root)"
echo
echo -e "  ${BOLD}noVNC (remote desktop):${NC}"
if [[ "$EXPOSE_LAN" == "1" ]]; then
    echo -e "    https://${CT_IP}:6080/vnc.html   (self-signed certificate: accept the browser warning)"
else
    echo -e "    http://localhost:6080/vnc.html   (after: ssh -L 6080:127.0.0.1:6080 -L 18789:127.0.0.1:18789 ${CT_USER}@${CT_IP})"
fi
echo -e "    VNC password: ${CYAN}${VNC_PASSWORD}${NC}"
echo
echo -e "  ${BOLD}OpenClaw Dashboard${NC} (loopback only — use the desktop shortcut or the tunnel above):"
echo -e "    http://localhost:18789/"
echo -e "    Auth token: ${CYAN}${AUTH_TOKEN}${NC}"
echo
echo -e "  ${BOLD}Browser Extension:${NC}"
echo -e "    Follow the output of 'openclaw browser extension install' (saved to ~/openclaw-extension.txt)."
if [[ -n "$EXT_INFO" ]]; then
    echo -e "    Output of 'openclaw browser extension install':"
    while IFS= read -r line; do echo "      $line"; done <<<"$EXT_INFO"
fi
echo
echo -e "  ${BOLD}SSH:${NC}"
echo -e "    ssh ${CT_USER}@${CT_IP}   (root SSH login is disabled; use 'pct enter $VMID' for a root shell)"
echo
echo -e "  ${BOLD}Manage container:${NC}"
echo -e "    pct enter $VMID"
echo -e "    pct stop $VMID"
echo -e "    pct start $VMID"
echo
