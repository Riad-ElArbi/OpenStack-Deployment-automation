#!/usr/bin/env bash
# ============================================================
#  OpenStack All-in-One  –  Kolla-Ansible 2025.2 (stable)
#  Ubuntu 24.04 · Hyper-V · user: openstack
#  Run as:  bash deploy_openstack.sh
# ============================================================

set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fail()  { echo -e "${RED}[FAIL]${RESET}  $*" >&2; exit 1; }

# ─── Guard: must NOT run as root ─────────────────────────────
[[ "$EUID" -ne 0 ]] || fail "Run this script as the 'openstack' user (not root/sudo)."

CURRENT_USER=$(id -un)
info "Running as: $CURRENT_USER  (uid=$UID)"

# ─── Step tracker ────────────────────────────────────────────
STEP=0
step() { STEP=$((STEP+1)); echo -e "\n${BOLD}━━━ Step $STEP: $* ━━━${RESET}"; }

# ════════════════════════════════════════════════════════════
step "Passwordless sudo"
# ════════════════════════════════════════════════════════════
SUDOERS_LINE="${CURRENT_USER} ALL=(ALL:ALL) NOPASSWD:ALL"
if sudo grep -q "^${CURRENT_USER}" /etc/sudoers 2>/dev/null; then
    ok "sudoers entry already present"
else
    echo "$SUDOERS_LINE" | sudo tee /etc/sudoers.d/99-openstack-user > /dev/null
    sudo chmod 0440 /etc/sudoers.d/99-openstack-user
    ok "Passwordless sudo configured"
fi

# ════════════════════════════════════════════════════════════
step "Verify KVM / nested virtualisation"
# ════════════════════════════════════════════════════════════
info "Checking KVM availability …"
sudo apt-get install -y -qq cpu-checker > /dev/null || true
if ! sudo kvm-ok 2>&1 | grep -q "KVM acceleration can be used"; then
    warn "kvm-ok did NOT confirm KVM. Attempting to load kvm_intel …"
fi

# Load kvm-intel with nested=1
sudo modprobe kvm_intel nested=1 2>/dev/null || \
    warn "kvm_intel module could not be loaded (expected in some Hyper-V setups)"

if ! grep -q "kvm-intel" /etc/modprobe.d/kvm-intel.conf 2>/dev/null; then
    echo "options kvm-intel nested=1" | sudo tee /etc/modprobe.d/kvm-intel.conf > /dev/null
fi

sudo modprobe -r kvm_intel 2>/dev/null || true
sudo modprobe  kvm_intel    2>/dev/null || warn "Could not reload kvm_intel"

NESTED=$(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || echo "N/A")
info "Nested virtualisation: ${NESTED}"
[[ "$NESTED" == "Y" || "$NESTED" == "1" ]] && ok "Nested virt enabled" \
    || warn "Nested virt not confirmed – continuing anyway"

# ════════════════════════════════════════════════════════════
step "Network configuration  (netplan)"
# ════════════════════════════════════════════════════════════
NETPLAN_FILE="/etc/netplan/network.yaml"
info "Writing $NETPLAN_FILE …"

sudo tee "$NETPLAN_FILE" > /dev/null <<'NETPLAN'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      addresses: [172.20.112.253/20]
      nameservers:
        addresses: [172.16.X.X]   # <-- replace X.X with your real DNS before applying
      routes:
        - to: default
          via: 172.20.112.1
    eth1:
      dhcp4: false
      dhcp6: false
      accept-ra: false
NETPLAN

ok "Netplan file written"

echo -e "\n${YELLOW}┌─────────────────────────────────────────────────────────┐"
echo -e "│  ✏️   MANUAL EDIT REQUIRED  –  network.yaml              │"
echo -e "│                                                         │"
echo -e "│  Open a NEW terminal tab/window and run:                │"
echo -e "│    sudo nano $NETPLAN_FILE          │"
echo -e "│                                                         │"
echo -e "│  Things to check / change:                              │"
echo -e "│   • Replace  172.16.X.X  with your real DNS IP          │"
echo -e "│   • Confirm IP 172.20.112.253/20 is correct for eth0    │"
echo -e "│   • Confirm gateway 172.20.112.1 is correct             │"
echo -e "│   • Confirm eth1 has no IP address                      │"
echo -e "└─────────────────────────────────────────────────────────┘${RESET}"
read -rp "  Press ENTER when you have saved and closed the file … "

sudo netplan apply && ok "Netplan applied" \
    || fail "netplan apply failed – check $NETPLAN_FILE"

ip -4 -br a

# ════════════════════════════════════════════════════════════
step "LVM volume group for Cinder  (/dev/sdb)"
# ════════════════════════════════════════════════════════════
if sudo vgs cinder-volumes &>/dev/null; then
    ok "Volume group 'cinder-volumes' already exists"
else
    sudo fdisk -l 2>/dev/null | grep "^Disk /dev/" | head -10
    if ! sudo test -b /dev/sdb; then
        fail "/dev/sdb not found. Attach the 50 GB 'ssd' disk in Hyper-V and rerun."
    fi
    sudo pvcreate /dev/sdb    && ok "PV created on /dev/sdb"
    sudo vgcreate cinder-volumes /dev/sdb && ok "VG 'cinder-volumes' created"
fi
sudo vgs

# ════════════════════════════════════════════════════════════
step "System update & base dependencies"
# ════════════════════════════════════════════════════════════
sudo apt-get update  -qq
sudo apt-get upgrade -y -qq
sudo apt-get install -y -qq \
    git python3-dev libffi-dev gcc libssl-dev \
    libdbus-glib-1-dev python3-venv
ok "Base packages installed"

# ════════════════════════════════════════════════════════════
step "Python virtual environment  (kolla-venv)"
# ════════════════════════════════════════════════════════════
VENV="$HOME/kolla-venv"
if [[ ! -d "$VENV" ]]; then
    python3 -m venv "$VENV"
    ok "venv created at $VENV"
else
    ok "venv already exists"
fi

# All remaining commands run inside the venv
source "$VENV/bin/activate"

pip install -q -U pip
pip install -q docker pkgconfig dbus-python
ok "pip & base Python packages upgraded"

# ════════════════════════════════════════════════════════════
step "Install Kolla-Ansible  2025.2 stable"
# ════════════════════════════════════════════════════════════
KOLLA_BRANCH="stable/2025.2"
KOLLA_URL="https://opendev.org/openstack/kolla-ansible"

info "Installing from ${KOLLA_URL}@${KOLLA_BRANCH} …"
pip install -q "git+${KOLLA_URL}@${KOLLA_BRANCH}" \
    || fail "kolla-ansible installation failed"
ok "kolla-ansible installed"

# ════════════════════════════════════════════════════════════
step "Kolla config directory & example files"
# ════════════════════════════════════════════════════════════
sudo mkdir -p /etc/kolla
sudo chown "$USER:$USER" /etc/kolla

SHARE="$VENV/share/kolla-ansible"
cp -r "$SHARE/etc_examples/kolla/"* /etc/kolla/
ok "Example configs copied to /etc/kolla"

# ════════════════════════════════════════════════════════════
step "Inventory file"
# ════════════════════════════════════════════════════════════
cp "$SHARE/ansible/inventory/all-in-one" "$HOME/all-in-one"
ok "Inventory copied to ~/all-in-one"

# ════════════════════════════════════════════════════════════
step "kolla-ansible install-deps"
# ════════════════════════════════════════════════════════════
kolla-ansible install-deps \
    || fail "kolla-ansible install-deps failed"
ok "Ansible dependencies installed"

# ════════════════════════════════════════════════════════════
step "Generate passwords  (kolla-genpwd)"
# ════════════════════════════════════════════════════════════
kolla-genpwd || fail "kolla-genpwd failed"
ok "Passwords generated"
info "Keystone admin password:"
grep keystone_admin_password /etc/kolla/passwords.yml | tee "$HOME/keystone_admin_password.txt"
ok "Password also saved to ~/keystone_admin_password.txt"

# ════════════════════════════════════════════════════════════
step "Write /etc/kolla/globals.yml"
# ════════════════════════════════════════════════════════════
info "Writing globals.yml …"

sudo tee /etc/kolla/globals.yml > /dev/null <<'GLOBALS'
---
# ── Kolla-Ansible globals.yml  –  2025.2 All-in-One ──────────
workaround_ansible_issue_8743: yes

kolla_base_distro: "ubuntu"

# VIP must be a free IP on the management network
kolla_internal_vip_address: "172.20.112.251"

# Management network interface (carries API & internal traffic)
network_interface: "eth0"

# External (Neutron) interface – must have NO IP address
neutron_external_interface: "eth1"

# Cinder block storage
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
GLOBALS

sudo chown "$USER:$USER" /etc/kolla/globals.yml
ok "globals.yml written"

echo -e "\n${YELLOW}┌─────────────────────────────────────────────────────────┐"
echo -e "│  ✏️   MANUAL EDIT REQUIRED  –  globals.yml               │"
echo -e "│                                                         │"
echo -e "│  Open a NEW terminal tab/window and run:                │"
echo -e "│    sudo nano /etc/kolla/globals.yml                     │"
echo -e "│                                                         │"
echo -e "│  Things to check / change:                              │"
echo -e "│   • kolla_internal_vip_address  (must be a free IP)     │"
echo -e "│   • network_interface           (management NIC name)   │"
echo -e "│   • neutron_external_interface  (external NIC name)     │"
echo -e "│   • Any extra services you want to enable/disable       │"
echo -e "└─────────────────────────────────────────────────────────┘${RESET}"
read -rp "  Press ENTER when you have saved and closed the file … "

# ════════════════════════════════════════════════════════════
step "Ping VIP to confirm it is free"
# ════════════════════════════════════════════════════════════
ip -4 -br a
if ping -c 3 -W 1 172.20.112.251 &>/dev/null; then
    fail "172.20.112.251 responds to ping – it is already in use! Change kolla_internal_vip_address in globals.yml."
else
    ok "172.20.112.251 is free – good"
fi

# ════════════════════════════════════════════════════════════
step "kolla-ansible bootstrap-servers"
# ════════════════════════════════════════════════════════════
kolla-ansible bootstrap-servers -i "$HOME/all-in-one" \
    || fail "bootstrap-servers failed"
ok "Bootstrap complete"

# ════════════════════════════════════════════════════════════
step "kolla-ansible prechecks"
# ════════════════════════════════════════════════════════════
kolla-ansible prechecks -i "$HOME/all-in-one" \
    || fail "prechecks failed – fix the reported issues and rerun this script from step 13"
ok "Pre-checks passed"

# ════════════════════════════════════════════════════════════
step "kolla-ansible deploy  (grab a coffee ☕)"
# ════════════════════════════════════════════════════════════
kolla-ansible deploy -i "$HOME/all-in-one" \
    || fail "deploy failed – check /var/log/kolla/ or rerun with -vvv"
ok "OpenStack deployed!"

# ════════════════════════════════════════════════════════════
step "Install OpenStack CLI client"
# ════════════════════════════════════════════════════════════
pip install -q python-openstackclient \
    -c "https://releases.openstack.org/constraints/upper/2025.2" \
    || fail "OpenStack client install failed"
ok "python-openstackclient installed"

# ════════════════════════════════════════════════════════════
step "Post-deploy tasks"
# ════════════════════════════════════════════════════════════
kolla-ansible post-deploy -i "$HOME/all-in-one" \
    || fail "post-deploy failed"

mkdir -p "$HOME/.config/openstack"
cp /etc/kolla/clouds.yaml "$HOME/.config/openstack/clouds.yaml"
ok "clouds.yaml copied"

# ════════════════════════════════════════════════════════════
step "~/.bashrc  –  env vars"
# ════════════════════════════════════════════════════════════
BASHRC="$HOME/.bashrc"
if ! grep -q "OS_CLOUD=kolla-admin" "$BASHRC"; then
cat >> "$BASHRC" <<'BASHRC_APPEND'

# ── OpenStack / Kolla env (added by deploy_openstack.sh) ──
export OS_CLOUD=kolla-admin
source ~/kolla-venv/bin/activate
BASHRC_APPEND
ok ".bashrc updated"
else
    ok ".bashrc already has OpenStack exports"
fi

# ════════════════════════════════════════════════════════════
step "Add $USER to docker group"
# ════════════════════════════════════════════════════════════
sudo usermod -aG docker "$USER"
ok "User added to docker group (re-login required)"

# ════════════════════════════════════════════════════════════
step "Copy & configure init-runonce, then run it"
# ════════════════════════════════════════════════════════════
cp "$SHARE/init-runonce" "$HOME/init-runonce"

# Patch the external network settings
sed -i \
    -e 's|EXT_NET_CIDR=.*|EXT_NET_CIDR=${EXT_NET_CIDR:-'"'"'172.20.112.0/20'"'"'}|' \
    -e 's|EXT_NET_RANGE=.*|EXT_NET_RANGE=${EXT_NET_RANGE:-'"'"'start=172.20.112.200,end=172.20.112.229'"'"'}|' \
    -e 's|EXT_NET_GATEWAY=.*|EXT_NET_GATEWAY=${EXT_NET_GATEWAY:-'"'"'172.20.112.1'"'"'}|' \
    "$HOME/init-runonce"

ok "init-runonce patched"

echo -e "\n${YELLOW}┌─────────────────────────────────────────────────────────┐"
echo -e "│  ✏️   MANUAL EDIT REQUIRED  –  init-runonce              │"
echo -e "│                                                         │"
echo -e "│  Open a NEW terminal tab/window and run:                │"
echo -e "│    nano \$HOME/init-runonce                              │"
echo -e "│                                                         │"
echo -e "│  Pre-patched values (verify these are correct):         │"
echo -e "│   • EXT_NET_CIDR    = 172.20.112.0/20                   │"
echo -e "│   • EXT_NET_RANGE   = start=172.20.112.200,             │"
echo -e "│                       end=172.20.112.229                │"
echo -e "│   • EXT_NET_GATEWAY = 172.20.112.1                      │"
echo -e "│   • DEMO_NET_CIDR   / DEMO_NET_GATEWAY (internal demo)  │"
echo -e "│   • IMAGE_URL       (CirrOS image, leave default)       │"
echo -e "└─────────────────────────────────────────────────────────┘${RESET}"
read -rp "  Press ENTER when you have saved and closed the file … "
source /etc/kolla/admin-openrc.sh 2>/dev/null || \
source "$HOME/.config/openstack/clouds.yaml" 2>/dev/null || true

bash "$HOME/init-runonce" \
    || fail "init-runonce failed – check above for error details"
ok "init-runonce completed"

# ════════════════════════════════════════════════════════════
step "Verification"
# ════════════════════════════════════════════════════════════
export OS_CLOUD=kolla-admin
openstack service list         && ok "Services listed"
openstack compute service list && ok "Compute services listed"
openstack network agent list   && ok "Network agents listed"
openstack volume service list  && ok "Volume services listed"
docker ps --format "table {{.Names}}\t{{.Status}}" | head -30

echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════════════════╗"
echo -e "║   OpenStack 2025.2 deployment COMPLETE  🎉       ║"
echo -e "║                                                  ║"
echo -e "║  Horizon UI: http://172.20.112.251               ║"
echo -e "║  Admin password: ~/keystone_admin_password.txt   ║"
echo -e "║  Re-login or: newgrp docker                      ║"
echo -e "╚══════════════════════════════════════════════════╝${RESET}\n"
