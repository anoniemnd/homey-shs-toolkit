#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo -e "\n[ERROR] ${BASH_SOURCE[0]}:${LINENO} failed while executing: ${BASH_COMMAND}" >&2' ERR

APP="Homey Self-Hosted Server"
TEMPLATE_FILE="${TEMPLATE_FILE:-debian-13-standard_13.1-2_amd64.tar.zst}"

# These will be set interactively
LXC_HOSTNAME=""
TEMPLATE_STORAGE=""
ROOTFS_STORAGE=""
DISK_SIZE_GB=""
CPU_CORES=""
RAM_MB=""
SWAP_MB=""
BRIDGE=""
PASSWORD=""
TAGS="homey;docker"
CTID=""
TEMPLATE_PATH=""
AUTOSTART_HOMEY_SHS=""
AUTO_UPDATE=""
VLAN_TAG=""

msg_info() { echo -e "  [INFO] $*"; }
msg_ok() { echo -e "  [ OK ] $*"; }
msg_warn() { echo -e "  [WARN] $*"; }
msg_error() { echo -e "  [FAIL] $*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "Run this script as root on the Proxmox host."
    exit 1
  fi
  if ! command -v pct >/dev/null 2>&1; then
    msg_error "pct command not found. This script must run on Proxmox VE."
    exit 1
  fi
  if ! command -v whiptail >/dev/null 2>&1; then
    msg_error "whiptail not found. Install with: apt install whiptail"
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    msg_error "jq not found. Install with: apt install jq"
    exit 1
  fi
}

# =============================================================================
# INTERACTIVE FUNCTIONS
# =============================================================================

get_next_ctid() {
  pvesh get /cluster/nextid
}

# Get storages that support a specific content type
# Usage: get_storages_for_content "rootdir" or "vztmpl"
get_storages_for_content() {
  local content_type="$1"
  # Use pvesh API to reliably get storage content types
  pvesh get /storage --output-format json 2>/dev/null | \
    jq -r --arg ct "$content_type" '.[] | select(.content | split(",") | any(. == $ct)) | .storage' | \
    sort
}

# Get available network bridges from Proxmox configuration
get_bridges() {
  pvesh get /nodes/$(hostname)/network --output-format json 2>/dev/null | \
    jq -r '.[] | select(.type == "bridge") | .iface' | \
    sort
}

# Check if a bridge is VLAN-aware
is_bridge_vlan_aware() {
  local bridge="$1"
  ip -d link show "$bridge" 2>/dev/null | grep -q "vlan_filtering 1"
}

# Whiptail menu helper
# Usage: select_from_list "title" "prompt" "option1" "option2" ...
select_from_list() {
  local title="$1"
  local prompt="$2"
  shift 2
  local options=("$@")
  local menu_items=()
  local i=1

  for opt in "${options[@]}"; do
    menu_items+=("$opt" "")
    ((i++))
  done

  whiptail --title "$title" --menu "$prompt" 16 60 8 "${menu_items[@]}" 3>&1 1>&2 2>&3
}

# Whiptail input helper
# Usage: get_input "title" "prompt" "default"
get_input() {
  local title="$1"
  local prompt="$2"
  local default="$3"

  whiptail --title "$title" --inputbox "$prompt" 10 60 "$default" 3>&1 1>&2 2>&3
}

# Whiptail yes/no helper
get_yes_no() {
  local title="$1"
  local prompt="$2"
  local default="${3:-yes}"
  
  # Bereken benodigde dimensies
  local height=$(($(echo -e "$prompt" | wc -l) + 8))  # +8 voor marges en knoppen
  local width=70  # Of bereken de langste regel
  
  if [[ "$default" == "no" ]]; then
    whiptail --title "$title" --yesno "$prompt" "$height" "$width" --defaultno 3>&1 1>&2 2>&3
  else
    whiptail --title "$title" --yesno "$prompt" "$height" "$width" 3>&1 1>&2 2>&3
  fi
}

interactive_setup() {
  local next_ctid storages_rootdir storages_vztmpl bridges

  # Get available options from Proxmox
  next_ctid=$(get_next_ctid)
  mapfile -t storages_rootdir < <(get_storages_for_content "rootdir")
  mapfile -t storages_vztmpl < <(get_storages_for_content "vztmpl")
  mapfile -t bridges < <(get_bridges)

  # Validate we have required resources
  if [[ ${#storages_rootdir[@]} -eq 0 ]]; then
    msg_error "No storage found that supports 'rootdir' content. Configure storage first."
    exit 1
  fi
  if [[ ${#storages_vztmpl[@]} -eq 0 ]]; then
    msg_error "No storage found that supports 'vztmpl' content. Configure storage first."
    exit 1
  fi
  if [[ ${#bridges[@]} -eq 0 ]]; then
    msg_error "No network bridges found."
    exit 1
  fi

  echo ""
  echo "=============================================="
  echo "  ${APP} - Interactive Setup"
  echo "=============================================="
  echo ""

  # 1. Container ID
  CTID=$(get_input "Container ID" "Enter container ID:" "$next_ctid") || exit 1

  # Validate CTID is not in use
  if pct status "$CTID" >/dev/null 2>&1; then
    msg_error "Container ID ${CTID} already exists!"
    exit 1
  fi

  # 2. Hostname
  LXC_HOSTNAME=$(get_input "Hostname" "Enter hostname for the container:" "homey-shs") || exit 1

  # 3. Template storage (for downloading debian template)
  if [[ ${#storages_vztmpl[@]} -eq 1 ]]; then
    TEMPLATE_STORAGE="${storages_vztmpl[0]}"
    msg_info "Template storage: ${TEMPLATE_STORAGE} (only option)"
  else
    TEMPLATE_STORAGE=$(select_from_list "Template Storage" "Select storage for container template:" "${storages_vztmpl[@]}") || exit 1
  fi

  # 4. Root filesystem storage
  if [[ ${#storages_rootdir[@]} -eq 1 ]]; then
    ROOTFS_STORAGE="${storages_rootdir[0]}"
    msg_info "Root filesystem storage: ${ROOTFS_STORAGE} (only option)"
  else
    ROOTFS_STORAGE=$(select_from_list "Root Filesystem Storage" "Select storage for container root filesystem:" "${storages_rootdir[@]}") || exit 1
  fi

  # 5. Network bridge
  if [[ ${#bridges[@]} -eq 1 ]]; then
    BRIDGE="${bridges[0]}"
    msg_info "Network bridge: ${BRIDGE} (only option)"
  else
    BRIDGE=$(select_from_list "Network Bridge" "Select network bridge:" "${bridges[@]}") || exit 1
  fi

  # 6. VLAN tag (optional, only if bridge is VLAN-aware)
  if is_bridge_vlan_aware "$BRIDGE"; then
    VLAN_TAG=$(get_input "VLAN Tag" "Enter VLAN tag (leave empty for no VLAN):" "") || exit 1
  else
    VLAN_TAG=""
  fi

  # 7. Resources
  DISK_SIZE_GB=$(get_input "Disk Size" "Enter disk size in GB:" "16") || exit 1
  CPU_CORES=$(get_input "CPU Cores" "Enter number of CPU cores:" "2") || exit 1
  RAM_MB=$(get_input "RAM" "Enter RAM in MB:" "2048") || exit 1
  SWAP_MB=$(get_input "Swap" "Enter swap in MB:" "512") || exit 1

  # 8. Password
  PASSWORD=$(get_input "Root Password" "Enter root password for container:" "homey") || exit 1

  # 9. Autostart Homey SHS service?
  if get_yes_no "Autostart Homey SHS" "Start Homey SHS immediately after installation?\n\nChoose 'No' if you want to replace userdata first (migration).\n\nNote: When choosing 'No' Homey-SHS will auto-start on every future container reboot. See 'Migration Guide' for details." "yes"; then
    AUTOSTART_HOMEY_SHS="yes"
  else
    AUTOSTART_HOMEY_SHS="no"
  fi

  # 10. Auto-update Docker image?
  if get_yes_no "Auto Update" "Enable automatic updates for Homey SHS?\n\nYes = Pull latest image on every restart\nNo  = Manual updates only" "yes"; then
    AUTO_UPDATE="yes"
  else
    AUTO_UPDATE="no"
  fi

  # Build template path
  TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}"

  # Show summary
  show_summary
}

show_summary() {
  local summary
  summary=$(cat <<EOF
Configuration Summary:

  Container ID     : ${CTID}
  Hostname         : ${LXC_HOSTNAME}
  Template Storage : ${TEMPLATE_STORAGE}
  Rootfs Storage   : ${ROOTFS_STORAGE}
  Network Bridge   : ${BRIDGE}
  VLAN Tag         : ${VLAN_TAG:-none}
  Disk Size        : ${DISK_SIZE_GB} GB
  CPU Cores        : ${CPU_CORES}
  RAM              : ${RAM_MB} MB
  Swap             : ${SWAP_MB} MB
  Root Password    : ${PASSWORD}
  Autostart Homey  : ${AUTOSTART_HOMEY_SHS}
  Auto Update      : ${AUTO_UPDATE}

Proceed with installation?
EOF
)

  if ! whiptail --title "Confirm Settings" --yesno "$summary" 25 55; then
    msg_info "Installation cancelled."
    exit 0
  fi
}

ensure_template() {
  if pveam list "$TEMPLATE_STORAGE" | awk 'NR>2 {print $2}' | grep -Fxq "$TEMPLATE_FILE"; then
    msg_ok "Template ${TEMPLATE_FILE} already present in ${TEMPLATE_STORAGE}"
  else
    msg_info "Downloading ${TEMPLATE_FILE} to ${TEMPLATE_STORAGE}"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_FILE"
    msg_ok "Template downloaded"
  fi
}

create_container() {
  msg_info "Creating LXC ${CTID} (${APP})"
  pct create "$CTID" "$TEMPLATE_PATH" \
    -arch amd64 \
    -ostype debian \
    -hostname "$LXC_HOSTNAME" \
    -tags "$TAGS" \
    -onboot 1 \
    -cores "$CPU_CORES" \
    -memory "$RAM_MB" \
    -swap "$SWAP_MB" \
    -storage "$ROOTFS_STORAGE" \
    -rootfs "${ROOTFS_STORAGE}:${DISK_SIZE_GB}" \
    -password "$PASSWORD" \
    -net0 "name=eth0,bridge=${BRIDGE}${VLAN_TAG:+,tag=$VLAN_TAG},ip=dhcp,type=veth" \
    -unprivileged 1 \
    -features nesting=1 \
    -cmode console >/dev/null
  msg_ok "Container ${CTID} created (password: ${PASSWORD})"
}

start_container() {
  msg_info "Starting LXC ${CTID}"
  pct start "$CTID"
  for i in {1..20}; do
    sleep 3
    if pct exec "$CTID" -- bash -c "ping -c1 -W1 1.1.1.1 >/dev/null 2>&1"; then
      msg_ok "Network connectivity confirmed"
      return
    fi
  done
  msg_warn "Unable to verify outbound network connectivity. Continuing anyway."
}

configure_homey_shs() {
  local log_file="/tmp/homey-shs-install-${CTID}.log"
  msg_info "Installing Docker and Homey SHS inside the container..."
  msg_info "Log file: ${log_file}"

  pct exec "$CTID" -- bash <<'IN_CONTAINER' >>"$log_file" 2>&1
set -Eeuo pipefail
apt-get update
apt-get install -y curl sudo jq ca-certificates gnupg

mkdir -p /etc/docker
cat <<'DOCKER_JSON' >/etc/docker/daemon.json
{
  "log-driver": "journald"
}
DOCKER_JSON

sh <(curl -fsSL https://get.docker.com)

HOMEY_DATA_DIR="/root/.homey-shs"
DEPLOY_SCRIPT="/usr/local/bin/homey-shs.sh"
SERVICE_PATH="/etc/systemd/system/homey-shs.service"

mkdir -p "$HOMEY_DATA_DIR"
cat <<'DEPLOY_SCRIPT' >"$DEPLOY_SCRIPT"
#!/usr/bin/env bash
set -Eeuo pipefail
IMAGE="ghcr.io/athombv/homey-shs"
CONTAINER="homey-shs"
DATA_DIR="/root/.homey-shs"
AUTO_UPDATE="__AUTO_UPDATE_PLACEHOLDER__"

mkdir -p "$DATA_DIR"

# Pull image: always if AUTO_UPDATE=yes, otherwise only if image doesn't exist
if [[ "$AUTO_UPDATE" == "yes" ]] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if ! docker pull "$IMAGE"; then
    echo "[homey-shs] Warning: docker pull failed; continuing with cached image if available" >&2
  fi
fi

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run \
  --name="$CONTAINER" \
  --network host \
  --privileged \
  --detach \
  --restart unless-stopped \
  --volume "$DATA_DIR":/homey/user/ \
  "$IMAGE"
DEPLOY_SCRIPT
chmod +x "$DEPLOY_SCRIPT"

cat <<SERVICE_UNIT >"$SERVICE_PATH"
[Unit]
Description=Homey Self-Hosted Server Container
Wants=docker.service network-online.target
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$DEPLOY_SCRIPT

[Install]
WantedBy=multi-user.target
SERVICE_UNIT

systemctl daemon-reload
IN_CONTAINER

  # Set AUTO_UPDATE value in deploy script
  pct exec "$CTID" -- sed -i "s/__AUTO_UPDATE_PLACEHOLDER__/${AUTO_UPDATE}/" /usr/local/bin/homey-shs.sh

  # Enable (and optionally start) the Homey SHS service
  if [[ "$AUTOSTART_HOMEY_SHS" == "yes" ]]; then
    msg_info "Enabling and starting Homey SHS service"
    pct exec "$CTID" -- systemctl enable --now homey-shs.service
  else
    msg_info "Enabling Homey SHS service (will start on next boot)"
    pct exec "$CTID" -- systemctl enable homey-shs.service
  fi

  msg_ok "Homey SHS deployment complete"
}

print_summary() {
  local ip_output ip_status ip_addr

  ip_output=$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>&1)
  ip_status=$?
  if [[ $ip_status -eq 0 ]]; then
    ip_addr=$(awk '{print $4}' <<<"$ip_output" | cut -d/ -f1)
  else
    ip_addr="unknown"
    msg_warn "Unable to read IP address (pct exec output: $ip_output)"
  fi

  echo -e "\n${APP} (${CTID}) is ready."
  echo -e "  Hostname     : $LXC_HOSTNAME"
  echo -e "  IP           : ${ip_addr}"
  echo -e "  SSH Username : root"
  echo -e "  SSH Password : $PASSWORD"
  echo -e "  HTTP Address : http://${ip_addr}:4859"
  echo -e "  Install log  : /tmp/homey-shs-install-${CTID}.log"

  if [[ "$AUTOSTART_HOMEY_SHS" == "no" ]]; then
    echo -e ""
    echo -e "  NOTE: Homey SHS service is installed but NOT running."
    echo -e "        You can now replace userdata in /root/.homey-shs/"
    echo -e "        Then start with: pct exec ${CTID} -- systemctl start homey-shs"
  fi

  if [[ "$AUTO_UPDATE" == "no" ]]; then
    echo -e ""
    echo -e "  Manual updates: pct exec ${CTID} -- docker pull ghcr.io/athombv/homey-shs"
    echo -e "                  pct exec ${CTID} -- systemctl restart homey-shs"
  fi
}

# =============================================================================
# MAIN
# =============================================================================

require_root
interactive_setup
ensure_template
create_container
start_container
configure_homey_shs
print_summary
