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
#            TMPL_STORAGE ROOT_STORAGE ONBOOT
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

cleanup() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 && CT_CREATED )); then
        err "Setup failed. Container $VMID was left in place for inspection."
        err "  Inspect:  pct enter $VMID"
        err "  Remove:   pct stop $VMID; pct destroy $VMID --purge"
        if [[ -t 0 && -t 1 ]]; then
            local answer=""
            read -rp "Destroy container $VMID now? [y/N]: " answer || true
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                pct stop "$VMID" >/dev/null 2>&1 || true
                pct destroy "$VMID" --purge >/dev/null 2>&1 \
                    && info "Container $VMID destroyed." \
                    || err "Could not destroy container $VMID."
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
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )) \
        || fatal "$name must be a whole number between $min and $max (got '$value')."
}

echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     OpenClaw LXC Setup for Proxmox               ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
echo

if [[ -z "${CT_PASSWORD:-}" ]]; then
    [[ -t 0 ]] || fatal "No terminal available — set CT_PASSWORD in the environment."
    read -rp "Container password: " -s CT_PASSWORD
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
CT_HOSTNAME="${CT_HOSTNAME:-openclaw}"
BRIDGE="${BRIDGE:-vmbr0}"
ONBOOT="${ONBOOT:-1}"

require_int DISK_SIZE 4 100000
require_int MEMORY 1024 1000000
require_int CORES 1 512
[[ "$VNC_RES" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]] || fatal "VNC resolution must look like 1920x1080 (got '$VNC_RES')."
[[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || fatal "Invalid hostname '$CT_HOSTNAME'."
[[ "$BRIDGE" =~ ^[a-zA-Z0-9_.-]+$ ]] || fatal "Invalid bridge name '$BRIDGE'."
[[ "$ONBOOT" =~ ^[01]$ ]] || fatal "ONBOOT must be 0 or 1."
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
    --password "$CT_PASSWORD" \
    --rootfs "${ROOT_STORAGE}:${DISK_SIZE}" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged 0 \
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
    CT_IP=$(ct_exec "hostname -I 2>/dev/null" | awk '{print $1}' || true)
    [[ -n "$CT_IP" && "$CT_IP" != "127.0.0.1" ]] && break
    CT_IP=""
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

# ─── Install packages inside the container ────────────────────────────────────
info "Updating packages and installing prerequisites..."
ct_exec "
    export DEBIAN_FRONTEND=noninteractive

    # Fix locale warnings
    apt-get update && apt-get install -y locales 2>&1 | grep -v 'Failed to write'
    sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    locale-gen en_US.UTF-8 >/dev/null 2>&1
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    apt-get upgrade -y 2>&1 | grep -v 'Failed to write'
    apt-get install -y curl ca-certificates gnupg git 2>&1 | grep -v 'Failed to write'
"
ok "Prerequisites installed."

info "Installing Node.js 22..."
ct_exec "
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>&1 | tail -3
    apt-get install -y nodejs 2>&1 | grep -v 'Failed to write'
"
ok "Node.js installed."

info "Installing Homebrew (required for OpenClaw skills)..."
ct_exec "
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y build-essential procps file 2>&1 | grep -v -E 'Failed to write|Permission denied'

    # Homebrew must be installed as a non-root user
    useradd -m -s /bin/bash brewuser 2>/dev/null || true
    echo 'brewuser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/brewuser

    # Install Homebrew as brewuser
    su - brewuser -c 'NONINTERACTIVE=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"' 2>&1 | tail -5

    # Make brew available system-wide for root
    echo '[ -x /home/linuxbrew/.linuxbrew/bin/brew ] && eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"' >> /root/.bashrc
    ln -sf /home/linuxbrew/.linuxbrew/bin/brew /usr/local/bin/brew
"
ok "Homebrew installed."

info "Installing OpenClaw..."
ct_exec "npm install -g openclaw@latest 2>&1 | tail -5"
ok "OpenClaw installed."

info "Installing LXQt, TigerVNC, noVNC (this takes a few minutes)..."
ct_exec "
    export DEBIAN_FRONTEND=noninteractive
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    apt-get install -y lxqt openbox lxterminal tigervnc-standalone-server novnc websockify dbus-x11 fonts-noto-color-emoji 2>&1 \
        | grep -v -E 'Failed to write|Failed to send reload|Permission denied|Cannot set LC_'
"
ok "Desktop environment installed."

info "Installing Google Chrome..."
ct_exec "
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb
    apt-get install -y /tmp/chrome.deb 2>&1 | grep -v -E 'Failed to write|Permission denied'
    rm -f /tmp/chrome.deb
"
ok "Google Chrome installed."

# ─── Configure OpenClaw ──────────────────────────────────────────────────────
info "Configuring OpenClaw..."
AUTH_TOKEN=$(openssl rand -hex 16)

ct_exec "
    openclaw config set gateway.mode local
    openclaw config set gateway.bind lan
    openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true
    openclaw config set gateway.auth.token '${AUTH_TOKEN}'
"
ok "OpenClaw configured (token: $AUTH_TOKEN)."

info "Installing OpenClaw browser extension..."
ct_exec "openclaw browser extension install 2>&1 | tail -5 || true"
ok "OpenClaw browser extension installed."

# ─── Configure VNC ───────────────────────────────────────────────────────────
info "Configuring VNC..."
ct_exec "
    mkdir -p /root/.config/tigervnc
    echo '${CT_PASSWORD}' | vncpasswd -f > /root/.config/tigervnc/passwd
    chmod 600 /root/.config/tigervnc/passwd
"

ct_exec "cat > /root/.config/tigervnc/xstartup << 'XSTARTUP'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session startlxqt
XSTARTUP
chmod +x /root/.config/tigervnc/xstartup"

# Configure lxterminal with dark theme
ct_exec "
    mkdir -p /root/.config/lxterminal
    cat > /root/.config/lxterminal/lxterminal.conf << 'CONF'
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
"

# Set noVNC scaling to auto by default
ct_exec "sed -i \"s/UI.initSetting('resize', 'off')/UI.initSetting('resize', 'scale')/\" /usr/share/novnc/app/ui.js"
ok "VNC configured (auto-scaling enabled)."

# ─── Disable LXC-incompatible LXQt components ───────────────────────────────
info "Disabling LXC-incompatible LXQt components..."
ct_exec "
    mkdir -p /root/.config/autostart
    # Disable power management (no hardware in LXC)
    cat > /root/.config/autostart/lxqt-powermanagement.desktop << 'NOAUTO'
[Desktop Entry]
Type=Application
Name=LXQt Power Management
Hidden=true
NOAUTO
    # Disable screen saver (not needed in VNC)
    cat > /root/.config/autostart/lxqt-xscreensaver-autostart.desktop << 'NOAUTO'
[Desktop Entry]
Type=Application
Name=LXQt Screen Saver
Hidden=true
NOAUTO
"
ok "LXC-incompatible components disabled."

# ─── Configure Google Chrome for root user ───────────────────────────────────
info "Configuring Google Chrome..."
ct_exec "
    # Chrome requires --no-sandbox when running as root
    sed -i 's|Exec=/usr/bin/google-chrome-stable|Exec=/usr/bin/google-chrome-stable --no-sandbox|g' /usr/share/applications/google-chrome.desktop

    mkdir -p /root/Desktop
    cp /usr/share/applications/google-chrome.desktop /root/Desktop/
    chmod +x /root/Desktop/google-chrome.desktop

    # Wrapper so CLI calls also get --no-sandbox
    cat > /usr/local/bin/google-chrome << 'WRAPPER'
#!/bin/bash
exec /usr/bin/google-chrome-stable --no-sandbox \"\$@\"
WRAPPER
    chmod +x /usr/local/bin/google-chrome

    update-alternatives --set x-www-browser /usr/bin/google-chrome-stable 2>/dev/null || true
    update-alternatives --set gnome-www-browser /usr/bin/google-chrome-stable 2>/dev/null || true
    xdg-mime default google-chrome.desktop x-scheme-handler/http 2>/dev/null || true
    xdg-mime default google-chrome.desktop x-scheme-handler/https 2>/dev/null || true
    xdg-mime default google-chrome.desktop text/html 2>/dev/null || true
"
ok "Google Chrome configured."

# ─── Configure LXQt default terminal ─────────────────────────────────────────
info "Setting lxterminal as default terminal..."
ct_exec "
    mkdir -p /root/.config/lxqt
    cat > /root/.config/lxqt/session.conf << 'CONF'
[General]
__userfile__=true

[Environment]
TERM=xterm-256color

[Preferred Applications]
terminal_emulator=lxterminal
CONF
"
ok "Default terminal configured."

# ─── Create desktop shortcuts ────────────────────────────────────────────────
info "Creating desktop shortcuts..."

# Terminal shortcut
ct_exec "cat > /root/Desktop/terminal.desktop << 'SHORTCUT'
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
chmod +x /root/Desktop/terminal.desktop"

# OpenClaw Onboarding wizard (runs in terminal)
ct_exec "cat > /root/Desktop/openclaw-onboard.desktop << 'SHORTCUT'
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
chmod +x /root/Desktop/openclaw-onboard.desktop"

# OpenClaw Dashboard (opens in Chrome with token)
ct_exec "cat > /root/Desktop/openclaw-dashboard.desktop << SHORTCUT
[Desktop Entry]
Version=1.0
Type=Application
Name=OpenClaw Dashboard
Comment=Open the OpenClaw Control UI in Google Chrome
Exec=google-chrome-stable --no-sandbox http://127.0.0.1:18789/#token=${AUTH_TOKEN}
Icon=web-browser
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
SHORTCUT
chmod +x /root/Desktop/openclaw-dashboard.desktop"

ok "Desktop shortcuts created."

# ─── Create systemd services ─────────────────────────────────────────────────
info "Creating systemd services..."

ct_exec "cat > /etc/systemd/system/openclaw-gateway.service << 'SVC'
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
ExecStart=/bin/openclaw gateway run --bind lan --auth token
Restart=always
RestartSec=5
Environment=NODE_ENV=production
WorkingDirectory=/root

[Install]
WantedBy=multi-user.target
SVC"

ct_exec "cat > /etc/systemd/system/vncserver.service << SVC
[Unit]
Description=TigerVNC Server
After=network.target

[Service]
Type=forking
Environment=HOME=/root
ExecStartPre=/bin/sh -c \"/usr/bin/vncserver -kill :1 > /dev/null 2>&1 || :\"
ExecStart=/usr/bin/vncserver :1 -geometry ${VNC_RES} -depth 24 -localhost yes
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC"

ct_exec "cat > /etc/systemd/system/novnc.service << 'SVC'
[Unit]
Description=noVNC WebSocket Proxy
After=vncserver.service
Requires=vncserver.service

[Service]
Type=simple
ExecStart=/bin/websockify --web=/usr/share/novnc/ 6080 localhost:5901
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC"

ct_exec "
    systemctl daemon-reload
    systemctl enable --now openclaw-gateway.service
    systemctl enable --now vncserver.service
    systemctl enable --now novnc.service
"
ok "All services enabled and started."

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
CT_IP=$(ct_exec "hostname -I 2>/dev/null" | awk '{print $1}' || echo "unknown")

# ─── Print connection info ────────────────────────────────────────────────────
echo
echo -e "${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           OpenClaw LXC Setup Complete!            ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
echo
echo -e "  ${BOLD}Container ID:${NC}  $VMID"
echo -e "  ${BOLD}Container IP:${NC}  $CT_IP"
echo
echo -e "  ${BOLD}OpenClaw Dashboard:${NC}"
echo -e "    http://${CT_IP}:18789/"
echo -e "    Auth token: ${CYAN}${AUTH_TOKEN}${NC}"
echo
echo -e "  ${BOLD}noVNC (remote desktop):${NC}"
echo -e "    http://${CT_IP}:6080/vnc.html"
echo -e "    VNC password: (same as container password)"
echo
echo -e "  ${BOLD}Browser Extension:${NC}"
echo -e "    Open Chrome → chrome://extensions → Enable Developer Mode"
echo -e "    Click 'Load unpacked' and select the OpenClaw extension directory"
echo
echo -e "  ${BOLD}SSH:${NC}"
echo -e "    ssh root@${CT_IP}"
echo
echo -e "  ${BOLD}Manage container:${NC}"
echo -e "    pct enter $VMID"
echo -e "    pct stop $VMID"
echo -e "    pct start $VMID"
echo
