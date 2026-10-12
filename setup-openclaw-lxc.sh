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
# Supported: CT_PASSWORD DISK_SIZE MEMORY CORES VNC_RES VMID CT_HOSTNAME
#            BRIDGE IP_ADDRESS GATEWAY NAMESERVER SEARCHDOMAIN VLAN_TAG MTU SWAP TIMEZONE
#            TMPL_STORAGE ROOT_STORAGE ONBOOT PRIVILEGED NODE_MAJOR OPENCLAW_VERSION
#            HOMEBREW_INSTALL_REF EXPOSE_LAN
#

set -euo pipefail

# ─── Output helpers ───────────────────────────────────────────────────────────
# Colors only on a terminal, and never when NO_COLOR is set (https://no-color.org)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

START_TIME=$SECONDS
STEP_NO=0
STEP_TOTAL=6

info()  { echo -e "${CYAN}•${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
err()   { echo -e "${RED}✘ $*${NC}" >&2; }
fatal() { err "$@"; exit 1; }

# in_array NEEDLE ITEM... — true if NEEDLE is one of the items
in_array() {
    local needle="$1" item
    shift
    for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
    return 1
}

# choose_option VAR LABEL DEFAULT ITEM... — numbered menu on a TTY (when there is a choice),
# otherwise DEFAULT. A preset VAR is left alone.
choose_option() {
    local var="$1" label="$2" default="$3" choice="" n=0 item
    shift 3
    local -a items=("$@")
    [[ -z "${!var:-}" ]] || return 0
    if [[ -t 0 && ${#items[@]} -gt 1 ]]; then
        echo "Available ${label}:"
        for item in "${items[@]}"; do
            n=$((n + 1))
            printf '  %d) %s%s\n' "$n" "$item" "$([[ "$item" == "$default" ]] && echo '  (default)')"
        done
        read -rp "Select ${label} [${default}]: " choice
        if [[ -z "$choice" ]]; then
            choice="$default"
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
            choice="${items[choice - 1]}"
        fi
        in_array "$choice" "${items[@]}" || fatal "Invalid selection '${choice}'."
        default="$choice"
    fi
    printf -v "$var" '%s' "$default"
}

# stage TITLE — numbered section heading
stage() {
    STEP_NO=$((STEP_NO + 1))
    echo
    echo -e "${BOLD}${CYAN}[${STEP_NO}/${STEP_TOTAL}]${NC} ${BOLD}$*${NC}"
}

# kv LABEL VALUE — aligned "label  value" line
kv() { printf '  %s%-16s%s %s\n' "$BOLD" "$1" "$NC" "$2"; }

fmt_elapsed() {
    local t=$((SECONDS - START_TIME))
    printf '%dm %02ds' $((t / 60)) $((t % 60))
}

print_banner() {
    echo
    echo -e "${BOLD}  OpenClaw on Proxmox${NC}"
    echo -e "${DIM}  Debian 13 LXC · OpenClaw · LXQt desktop · Chrome · noVNC${NC}"
}

usage() {
    cat <<'USAGE'
Usage: setup-openclaw-lxc.sh [options]

Creates a Debian 13 LXC on this Proxmox host and installs OpenClaw, an LXQt desktop,
Google Chrome and VNC/noVNC. Run as root on the Proxmox host.

Options:
  -y, --yes    Do not ask for confirmation before creating the container
  -h, --help   Show this help

Every setting can also be preset through the environment (see the README), e.g.:
  CT_PASSWORD='secret' DISK_SIZE=64 EXPOSE_LAN=1 ./setup-openclaw-lxc.sh --yes
Set NO_COLOR=1 to disable colors.
USAGE
}

ASSUME_YES="${ASSUME_YES:-0}"
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        -y|--yes)  ASSUME_YES=1 ;;
        *)         fatal "Unknown option '$arg' (see --help)." ;;
    esac
done

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

print_banner
stage "Checking the host and collecting settings"

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
    local var="$1" prompt="$2" default="$3" reply="" hint
    [[ -z "${!var:-}" ]] || return 0
    hint="[$default]"
    [[ -n "$default" ]] || hint="(optional)"
    if [[ -t 0 ]]; then
        read -rp "$prompt $hint: " reply
    fi
    printf -v "$var" '%s' "${reply:-$default}"
}

require_int() { # require_int NAME MIN MAX
    local name="$1" min="$2" max="$3" value="${!1}"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || (( 10#$value < min || 10#$value > max )); then
        fatal "$name must be a whole number between $min and $max (got '$value')."
    fi
}

if [[ -z "${CT_PASSWORD:-}" ]]; then
    [[ -t 0 ]] || fatal "No terminal available — set CT_PASSWORD in the environment."
    read -rp "Password for the 'openclaw' user (SSH login): " -s CT_PASSWORD
    echo
    read -rp "Confirm password: " -s CT_PASSWORD_CONFIRM
    echo
    [[ "$CT_PASSWORD" == "$CT_PASSWORD_CONFIRM" ]] || fatal "Passwords do not match."
fi
[[ -n "$CT_PASSWORD" ]] || fatal "Password cannot be empty."
[[ "$CT_PASSWORD" != *$'\n'* ]] || fatal "Password cannot contain newlines."

ask VMID      "Container ID (VMID)" "$(pvesh get /cluster/nextid 2>/dev/null || echo 100)"
ask DISK_SIZE "Disk size in GB"  32
ask MEMORY    "Memory in MB"     4096
ask CORES     "CPU cores"        4
ask VNC_RES   "VNC resolution"   1920x1080
ask EXPOSE_LAN "Expose noVNC on the LAN over HTTPS? 1=yes 0=no (loopback only, use an SSH tunnel)" 0
ask CT_HOSTNAME "Hostname" openclaw

# ── Networking ──
mapfile -t BRIDGES < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 \
    | grep -Ev '^(fwbr|fwpr|fwln|docker|virbr|lxcbr)' || true)
if [[ -z "${BRIDGE:-}" ]]; then
    (( ${#BRIDGES[@]} > 0 )) || fatal "No network bridge found on this host. Create one (Proxmox: Network → Create → Linux Bridge) or set BRIDGE."
    BRIDGE_DEFAULT="${BRIDGES[0]}"
    if in_array vmbr0 "${BRIDGES[@]}"; then BRIDGE_DEFAULT=vmbr0; fi
    choose_option BRIDGE "network bridge" "$BRIDGE_DEFAULT" "${BRIDGES[@]}"
fi
ask IP_ADDRESS "IPv4 address as CIDR (e.g. 192.168.1.50/24), or 'dhcp'" dhcp
if [[ "$IP_ADDRESS" != "dhcp" ]]; then
    # Suggest the first host address of the network as the gateway
    GATEWAY_DEFAULT=$(python3 -c '
import ipaddress, sys
try:
    print(next(ipaddress.ip_interface(sys.argv[1]).network.hosts()))
except (ValueError, StopIteration):
    pass
' "$IP_ADDRESS" 2>/dev/null || true)
    ask GATEWAY "Gateway" "$GATEWAY_DEFAULT"
    HOST_DNS=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
    ask NAMESERVER "DNS server(s), space separated" "${HOST_DNS:-${GATEWAY:-1.1.1.1}}"
fi

# ── Advanced options (only asked on request; every one can be preset in the environment) ──
if [[ -t 0 && "$ASSUME_YES" != "1" ]]; then
    read -rp "Configure advanced options (VLAN, MTU, DNS search domain, swap, timezone, boot)? [y/N]: " ADVANCED
    if [[ "$ADVANCED" =~ ^[Yy] ]]; then
        ask VLAN_TAG      "VLAN tag"                 ""
        ask MTU           "MTU"                      ""
        ask SEARCHDOMAIN  "DNS search domain"        ""
        ask SWAP          "Swap in MB"               512
        ask TIMEZONE      "Timezone (e.g. Europe/Berlin, or 'host')" host
        ask ONBOOT        "Start on host boot (1/0)" 1
    fi
fi
GATEWAY="${GATEWAY:-}"
NAMESERVER="${NAMESERVER:-}"
SEARCHDOMAIN="${SEARCHDOMAIN:-}"
VLAN_TAG="${VLAN_TAG:-}"
MTU="${MTU:-}"
SWAP="${SWAP:-512}"
TIMEZONE="${TIMEZONE:-host}"
ONBOOT="${ONBOOT:-1}"
# Unprivileged by default; PRIVILEGED=1 is an explicit opt-in
PRIVILEGED="${PRIVILEGED:-0}"
[[ "$PRIVILEGED" =~ ^[01]$ ]] || fatal "PRIVILEGED must be 0 or 1."
UNPRIVILEGED=$(( 1 - PRIVILEGED ))

require_int DISK_SIZE 4 100000
require_int MEMORY 1024 1000000
require_int CORES 1 512
DISK_SIZE=$((10#$DISK_SIZE)); MEMORY=$((10#$MEMORY)); CORES=$((10#$CORES))
[[ "$VNC_RES" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]] || fatal "VNC resolution must look like 1920x1080 (got '$VNC_RES')."
[[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || fatal "Invalid hostname '$CT_HOSTNAME'."
[[ "$BRIDGE" =~ ^[a-zA-Z0-9_.-]+$ ]] || fatal "Invalid bridge name '$BRIDGE'."
[[ -z "$VLAN_TAG" ]] || { require_int VLAN_TAG 1 4094; VLAN_TAG=$((10#$VLAN_TAG)); }
[[ -z "$MTU" ]] || { require_int MTU 576 65535; MTU=$((10#$MTU)); }
require_int SWAP 0 1000000
SWAP=$((10#$SWAP))
[[ -z "$SEARCHDOMAIN" || "$SEARCHDOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || fatal "Invalid DNS search domain '$SEARCHDOMAIN'."
[[ "$TIMEZONE" == "host" || -e "/usr/share/zoneinfo/$TIMEZONE" ]] || fatal "Unknown timezone '$TIMEZONE' (use e.g. Europe/Berlin, or 'host')."
if [[ "$IP_ADDRESS" != "dhcp" ]]; then
    [[ -n "$GATEWAY" ]] || fatal "A static address needs a GATEWAY."
    python3 - "$IP_ADDRESS" "$GATEWAY" "$NAMESERVER" <<'PY' || fatal "Invalid static network settings."
import ipaddress, sys
addr, gw, dns = sys.argv[1:4]
try:
    iface = ipaddress.ip_interface(addr)
    if iface.version != 4 or "/" not in addr:
        raise ValueError("the address must be an IPv4 CIDR such as 192.168.1.50/24")
    gateway = ipaddress.ip_address(gw)
    if gateway.version != 4 or gateway not in iface.network:
        raise ValueError(f"gateway {gw} is not an IPv4 address inside {iface.network}")
    if gateway == iface.ip:
        raise ValueError("the gateway cannot be the container's own address")
    for server in dns.split():
        ipaddress.ip_address(server)
except ValueError as exc:
    print(f"Error: {exc}", file=sys.stderr)
    sys.exit(1)
PY
fi
[[ "$ONBOOT" =~ ^[01]$ ]] || fatal "ONBOOT must be 0 or 1."
[[ "$EXPOSE_LAN" =~ ^[01]$ ]] || fatal "EXPOSE_LAN must be 0 or 1."
ip link show "$BRIDGE" >/dev/null 2>&1 || fatal "Bridge '$BRIDGE' does not exist on this host."

if [[ "$IP_ADDRESS" != "dhcp" ]] && command -v ping >/dev/null 2>&1; then
    if ping -c 1 -W 1 "${IP_ADDRESS%/*}" >/dev/null 2>&1; then
        fatal "${IP_ADDRESS%/*} already answers ping — pick an unused address."
    fi
fi

echo

stage "Selecting storage and template"

# ─── Validate VMID ───────────────────────────────────────────────────────────
[[ "$VMID" =~ ^[0-9]+$ ]] || fatal "Invalid VMID '$VMID'."
pvesh get /cluster/nextid --vmid "$VMID" >/dev/null 2>&1 \
    || fatal "VMID $VMID is already in use (or outside Proxmox's allowed range 100-999999999)."
ok "Will use VMID: $VMID"

# ─── Auto-detect storage ─────────────────────────────────────────────────────
info "Detecting storage..."
NODE=$(hostname -s)

# Enabled storages on this node that can hold the given content type (JSON)
node_storage() {
    pvesh get "/nodes/$NODE/storage" --content "$1" --enabled 1 --output-format json 2>/dev/null
}

# pick_storage VAR CONTENT LABEL PREFERRED INTERACTIVE
#   Sets VAR to an enabled storage on this node that accepts CONTENT. A preset VAR is
#   validated; otherwise the user chooses from a menu (INTERACTIVE=1 on a TTY) or PREFERRED /
#   the storage with the most free space is used.
pick_storage() {
    local var="$1" content="$2" label="$3" preferred="$4" interactive="$5"
    local json rows name type avail default choice n=0
    local -a names=() avails=()

    json=$(node_storage "$content" || true)
    rows=$(python3 -c '
import json, sys
stores = json.load(sys.stdin)
for s in sorted(stores, key=lambda s: -s.get("avail", 0)):
    print("%s\t%s\t%.1f" % (s["storage"], s.get("type", "?"), s.get("avail", 0) / 2**30))
' <<<"$json" 2>/dev/null || true)
    [[ -n "$rows" ]] || fatal "No enabled storage on node '$NODE' accepts $label ($content)."

    while IFS=$'\t' read -r name type avail; do
        names+=("$name")
        avails+=("$avail")
    done <<<"$rows"

    if [[ -n "${!var:-}" ]]; then
        in_array "${!var}" "${names[@]}" \
            || fatal "Storage '${!var}' cannot be used for $label. Available: ${names[*]}"
        return 0
    fi

    default="${names[0]}"
    if in_array "$preferred" "${names[@]}"; then default="$preferred"; fi

    if [[ "$interactive" == "1" && -t 0 && ${#names[@]} -gt 1 ]]; then
        echo "Available storage for $label:"
        while IFS=$'\t' read -r name type avail; do
            n=$((n + 1))
            printf '  %d) %-20s %-10s %8s GB free%s\n' "$n" "$name" "$type" "$avail" \
                "$([[ "$name" == "$default" ]] && echo '  (default)')"
        done <<<"$rows"
        read -rp "Select $label [$default]: " choice
        if [[ -z "$choice" ]]; then
            choice="$default"
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
            choice="${names[choice - 1]}"
        fi
        in_array "$choice" "${names[@]}" || fatal "Invalid storage selection '$choice'."
        default="$choice"
    fi
    printf -v "$var" '%s' "$default"
}

TMPL_STORAGE="${TMPL_STORAGE:-}"
ROOT_STORAGE="${ROOT_STORAGE:-}"
pick_storage TMPL_STORAGE vztmpl  "container templates" local     0
pick_storage ROOT_STORAGE rootdir "the container disk"  local-lvm 1

ok "Template storage: $TMPL_STORAGE"
ok "Rootfs storage:   $ROOT_STORAGE"

ROOT_AVAIL=$(node_storage rootdir | python3 -c '
import json, sys
for s in json.load(sys.stdin):
    if s["storage"] == sys.argv[1]:
        print(int(s.get("avail", 0) / 2**30))
' "$ROOT_STORAGE" 2>/dev/null || true)
if [[ "$ROOT_AVAIL" =~ ^[0-9]+$ ]] && (( ROOT_AVAIL < DISK_SIZE )); then
    warn "Storage '$ROOT_STORAGE' reports only ~${ROOT_AVAIL} GB free for a ${DISK_SIZE} GB disk (fine for thin-provisioned storage)."
fi

# Debian 13 templates need a recent pve-container (reported fixed in 6.0.10 on PVE 9)
PVE_CONTAINER_VERSION=$(dpkg-query -W -f='${Version}' pve-container 2>/dev/null || true)
if [[ -n "$PVE_CONTAINER_VERSION" ]] && dpkg --compare-versions "$PVE_CONTAINER_VERSION" lt 6.0.10; then
    warn "pve-container $PVE_CONTAINER_VERSION may not support Debian 13 containers — if 'pct create' fails, run 'apt update && apt full-upgrade'."
fi

# ─── Download Debian 13 template ─────────────────────────────────────────────
info "Checking for Debian 13 template..."
pveam update >/dev/null 2>&1 || warn "pveam update failed — using the cached template index."

# Newest Debian 13 template in the index (version sort, not index order)
# The index can list several architectures; the container must match the host (arm64 sorts after
# amd64, so an unfiltered "newest" pick would select an arm64 template and fail to start).
HOST_ARCH=$(dpkg --print-architecture)
TEMPLATE=$(pveam available --section system 2>/dev/null \
    | grep -oP "debian-13-standard_\S+_${HOST_ARCH}\.tar\.\S+" | sort -V | tail -n 1 || true)
[[ -n "$TEMPLATE" ]] || fatal "Could not find a Debian 13 ${HOST_ARCH} template. Check 'pveam available --section system'."

# ─── Show the plan and confirm ───────────────────────────────────────────────
echo
echo -e "${BOLD}Plan${NC}"
kv "Container ID" "$VMID ($CT_HOSTNAME)"
kv "Resources" "${CORES} cores · ${MEMORY} MB RAM · ${DISK_SIZE} GB disk on ${ROOT_STORAGE}"
kv "Template" "$TEMPLATE (from ${TMPL_STORAGE})"
NET_DESC="$([[ "$IP_ADDRESS" == "dhcp" ]] && echo "DHCP" || echo "${IP_ADDRESS} via ${GATEWAY}") on ${BRIDGE}"
[[ -z "$VLAN_TAG" ]] || NET_DESC+=" · VLAN ${VLAN_TAG}"
[[ -z "$MTU" ]] || NET_DESC+=" · MTU ${MTU}"
kv "Network" "$NET_DESC"
if [[ -n "$NAMESERVER$SEARCHDOMAIN" ]]; then kv "DNS" "${NAMESERVER:-host default}${SEARCHDOMAIN:+ · search $SEARCHDOMAIN}"; fi
kv "Swap / timezone" "${SWAP} MB · ${TIMEZONE}"
if [[ "$PRIVILEGED" == "1" ]]; then kv "Container type" "privileged (not recommended)"; else kv "Container type" "unprivileged, nesting enabled"; fi
kv "Remote desktop" "${VNC_RES}, $([[ "$EXPOSE_LAN" == "1" ]] && echo "HTTPS on the LAN" || echo "loopback only (SSH tunnel)")"
kv "Start on boot" "$([[ "$ONBOOT" == "1" ]] && echo yes || echo no)"
if [[ "$ASSUME_YES" != "1" && -t 0 ]]; then
    echo
    read -rp "Create the container with these settings? [Y/n]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn] ]]; then
        warn "Aborted — nothing was changed."
        exit 1
    fi
fi

TEMPLATE_LIST=$(pveam list "$TMPL_STORAGE" 2>/dev/null || true)
if [[ "$TEMPLATE_LIST" == *"$TEMPLATE"* ]]; then
    ok "Template already downloaded: $TEMPLATE"
else
    info "Downloading $TEMPLATE to $TMPL_STORAGE..."
    pveam download "$TMPL_STORAGE" "$TEMPLATE"
    ok "Template downloaded."
fi

stage "Creating the container"

# ─── Create the LXC container ────────────────────────────────────────────────
info "Creating LXC container $VMID..."
NET0="name=eth0,bridge=${BRIDGE}"
if [[ "$IP_ADDRESS" == "dhcp" ]]; then
    NET0+=",ip=dhcp"
else
    NET0+=",ip=${IP_ADDRESS},gw=${GATEWAY}"
fi
[[ -z "$VLAN_TAG" ]] || NET0+=",tag=${VLAN_TAG}"
[[ -z "$MTU" ]] || NET0+=",mtu=${MTU}"

PCT_EXTRA=()
[[ -z "$NAMESERVER" ]] || PCT_EXTRA+=(--nameserver "$NAMESERVER")
[[ -z "$SEARCHDOMAIN" ]] || PCT_EXTRA+=(--searchdomain "$SEARCHDOMAIN")

pct create "$VMID" "${TMPL_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --rootfs "${ROOT_STORAGE}:${DISK_SIZE}" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 "$NET0" \
    --swap "$SWAP" \
    --timezone "$TIMEZONE" \
    "${PCT_EXTRA[@]}" \
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

stage "Waiting for the network"

# ─── Wait for network ────────────────────────────────────────────────────────
info "Waiting for the container's IPv4 address (up to 60s)..."
CT_IP=""
for _ in $(seq 1 60); do
    CT_IP=$(ct_ip)
    [[ -n "$CT_IP" ]] && break
    sleep 1
done
[[ -n "$CT_IP" ]] || fatal "Container got no IP address. Check bridge '$BRIDGE'$([[ "$IP_ADDRESS" == "dhcp" ]] && echo " (is there a DHCP server?)" || echo " and the VLAN/gateway settings")."
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
    printf 'NODE_MAJOR=%q\n'           "${NODE_MAJOR:-24}"
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

STEP_NO=0
STEP_TOTAL=$(grep -c '^step "' /root/provision.sh || true)
step() { STEP_NO=$((STEP_NO + 1)); echo "  [${STEP_NO}/${STEP_TOTAL}] $*"; }

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
# Enable en_US.UTF-8, generate it, and only export it once it really exists (exporting a
# missing locale makes bash/perl print "cannot change locale" warnings for every command)
sed -i 's/^# *\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
grep -q '^en_US\.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
quiet locale-gen
AVAILABLE_LOCALES=$(locale -a)
if [[ "$AVAILABLE_LOCALES" == *en_US.utf8* ]]; then
    CT_LOCALE=en_US.UTF-8
else
    echo "WARNING: en_US.UTF-8 could not be generated; falling back to C.UTF-8" >&2
    CT_LOCALE=C.UTF-8
fi
update-locale LANG="$CT_LOCALE"
export LANG="$CT_LOCALE" LC_ALL="$CT_LOCALE"
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
# Current OpenClaw releases require Node >=24.16.0 <25 or >=26.1.0 (Node 22/23/25 are unsupported)
if ! node -e '
const [maj, min] = process.versions.node.split(".").map(Number);
process.exit((maj === 24 && min >= 16) || (maj === 26 && min >= 1) || maj > 26 ? 0 : 1);
'; then
    echo "WARNING: Node.js $(node -v) is outside the range current OpenClaw supports (>=24.16 <25 or >=26.1); OpenClaw may refuse to start." >&2
fi

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
# npm 11.16+/12 blocks the package's install scripts unless explicitly allowed
NPM_FLAGS=()
if dpkg --compare-versions "$(npm -v)" ge 11.16.0; then NPM_FLAGS+=(--allow-scripts=openclaw); fi
quiet npm install -g "openclaw@${OPENCLAW_VERSION}" "${NPM_FLAGS[@]}"
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

# The extension installer needs Chrome's profile directory to exist, so start Chrome once.
step "Installing the OpenClaw browser extension"
as_user timeout 30 /usr/bin/google-chrome-stable --headless=new --disable-gpu --no-first-run \
    --dump-dom about:blank >/dev/null 2>&1 || true
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
Exec=lxterminal --title='OpenClaw Onboarding' -e sh -c 'OPENCLAW_SERVICE_REPAIR_POLICY=external openclaw onboard --skip-daemon; exec bash'
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
StartLimitBurst=10
StartLimitIntervalSec=300

[Service]
Type=simple
User=${CT_USER}
Environment=HOME=${USER_HOME}
Environment=NODE_ENV=production
Environment=OPENCLAW_SERVICE_REPAIR_POLICY=external
WorkingDirectory=${USER_HOME}
ExecStart=${OPENCLAW_BIN} gateway run --bind ${GATEWAY_BIND} --auth token
Restart=always
RestartSec=5
# Hardening/restart policy from the OpenClaw systemd guidance
RestartPreventExitStatus=78
SuccessExitStatus=0 143
TimeoutStartSec=30
TimeoutStopSec=330
KillMode=mixed
OOMPolicy=continue

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

stage "Provisioning the container"

# ─── Provision the container ─────────────────────────────────────────────────
info "Installing packages, desktop, Chrome and OpenClaw — this takes several minutes."
pct push "$VMID" "$WORKDIR/provision.env" /root/provision.env --perms 0600
pct push "$VMID" "$WORKDIR/provision.sh"  /root/provision.sh  --perms 0700
pct exec "$VMID" -- bash /root/provision.sh
ok "Container provisioned."

sleep 3

stage "Verifying services"

# ─── Verify services ─────────────────────────────────────────────────────────
info "Verifying services..."
SVC_FAILED=0
for svc in openclaw-gateway vncserver novnc; do
    if ct_exec "systemctl is-active --quiet $svc"; then
        ok "$svc is running."
    else
        SVC_FAILED=1
        warn "$svc failed to start. Check with: pct exec $VMID -- systemctl status $svc"
    fi
done

# Re-detect IP in case it changed
CT_IP=$(ct_ip)
CT_IP="${CT_IP:-unknown}"
EXT_INFO=$(ct_exec "cat /home/${CT_USER}/openclaw-extension.txt 2>/dev/null | tail -n 5" || true)

# ─── Print connection info ────────────────────────────────────────────────────
if [[ "$EXPOSE_LAN" == "1" ]]; then
    NOVNC_URL="https://${CT_IP}:6080/vnc.html"
    TUNNEL_NOTE="self-signed certificate — accept the browser warning"
else
    NOVNC_URL="http://localhost:6080/vnc.html"
    TUNNEL_NOTE="first run: ssh -L 6080:127.0.0.1:6080 -L 18789:127.0.0.1:18789 ${CT_USER}@${CT_IP}"
fi

summary() {
    local rule="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    if (( SVC_FAILED )); then
        echo -e "${YELLOW}${BOLD}  ! OpenClaw is installed, but a service did not start${NC}  ${DIM}(see warnings above)${NC}"
    else
        echo -e "${GREEN}${BOLD}  ✔ OpenClaw is ready${NC}  ${DIM}(finished in $(fmt_elapsed))${NC}"
    fi
    echo -e "${DIM}  ${rule}${NC}"
    kv "Container" "$VMID ($CT_HOSTNAME) · $CT_IP"
    kv "SSH login" "ssh ${CT_USER}@${CT_IP}   (no sudo; root shell: pct enter $VMID)"
    echo
    echo -e "  ${BOLD}${CYAN}Remote desktop${NC}"
    kv "URL" "$NOVNC_URL"
    kv "" "${DIM}${TUNNEL_NOTE}${NC}"
    kv "VNC password" "${CYAN}${VNC_PASSWORD}${NC}"
    echo
    echo -e "  ${BOLD}${CYAN}OpenClaw dashboard${NC}  ${DIM}(loopback only)${NC}"
    kv "URL" "http://localhost:18789/   ${DIM}or the Dashboard shortcut on the desktop${NC}"
    kv "Auth token" "${CYAN}${AUTH_TOKEN}${NC}"
    echo
    echo -e "  ${BOLD}${CYAN}Next steps${NC}"
    echo "    1. Open the remote desktop URL and sign in with the VNC password"
    echo "    2. Double-click \"OpenClaw Setup Wizard\" to configure channels and skills"
    echo "    3. Add the Chrome extension from the Chrome Web Store (ID kcdjddhmeafeomebliikmbpblkmkfoig),"
    echo "       then check it with: openclaw browser extension status"
    if [[ -n "$EXT_INFO" ]]; then
        echo -e "       ${DIM}extension install log (~/openclaw-extension.txt):${NC}"
        while IFS= read -r line; do echo -e "       ${DIM}${line}${NC}"; done <<<"$EXT_INFO"
    fi
    echo
    echo -e "  ${BOLD}${CYAN}Manage${NC}  ${DIM}pct enter $VMID · pct stop $VMID · pct start $VMID${NC}"
    echo -e "${DIM}  ${rule}${NC}"
}

summary

# Keep a private copy of the connection details (plain text, root only)
INFO_FILE="/root/openclaw-lxc-${VMID}.txt"
if (umask 077; BOLD='' DIM='' CYAN='' GREEN='' YELLOW='' NC='' summary > "$INFO_FILE" 2>/dev/null); then
    echo -e "  ${DIM}Connection details saved to ${INFO_FILE} (readable by root only).${NC}"
    echo
fi
