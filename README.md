# OpenStack 2025.2 All-in-One  –  Deployment Guide  [v2]
### Kolla-Ansible · Ubuntu 24.04 · Hyper-V

---

## 📦 Files in this package

| File | Purpose |
|------|---------|
| `create_vm.ps1` | PowerShell – creates the Hyper-V VM on Windows |
| `deploy_openstack.sh` | Bash – full OpenStack deployment inside the VM |
| `network.yaml` | Netplan config reference (172.20.112.0/20) |
| `globals.yml` | Kolla-Ansible globals config reference |

---

## Phase 1 — Create the Hyper-V VM (Windows host)

Open **PowerShell as Administrator** and simply run:

```powershell
.\create_vm.ps1
```

> **No parameters needed.** The script will automatically search every user's Desktop for a folder whose name contains "cloud" and "computing", then pick the first `ubuntu*.iso` inside it. If it cannot find the ISO automatically, it will ask you to type the full path manually.

The script will:
- Create VM **cloudServer** with **20 480 MB RAM (static)** and **2 vCPUs**
- Store all virtual disks in `C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\cloudServer\`
- Enable **nested virtualisation** (`ExposeVirtualizationExtensions = $true`)
- Create and attach a **300 GB** OS disk (`cloudServer_OS.vhdx`)
- Create and attach a **50 GB** SSD disk (`cloudServer_SSD.vhdx`) — used by Cinder LVM
- Add **two NICs** on "Default Switch" (`eth0` = management, `eth1` = Neutron external)
- **Disable Secure Boot** (required for Ubuntu on Gen 2 Hyper-V)
- Set **DVD as first boot device**
- Print a summary and next-step instructions

---

## Phase 2 — Install Ubuntu 24.04 (VM console)

Start the VM and follow the installer:

| Setting | Value |
|---------|-------|
| Language | **English** |
| Keyboard | **French – French (AZERTY)** |
| Username | **openstack** |
| Password | **root** |
| SSH | ✅ Install OpenSSH Server |
| Disk | Use entire 300 GB disk (leave 50 GB SSD untouched) |

After reboot, log in via SSH:

```bash
ssh openstack@<current-dhcp-ip>
```

---

## Phase 3 — Copy and run the deployment script (inside the VM)

### 3.1  Copy the script from Windows to the VM

```powershell
# Run this in PowerShell on your Windows machine
scp deploy_openstack.sh openstack@<dhcp-ip>:~/
```

Or open the VM console and paste the script contents directly.

### 3.2  Make it executable and launch it

```bash
chmod +x deploy_openstack.sh
./deploy_openstack.sh
```

The script runs fully automatically and prints colour-coded progress. It stops immediately on any error with a clear `[FAIL]` message showing exactly which step failed.

---

## ✏️ Three manual edit pauses

The script will **pause and wait for you** at three points. Each time, a yellow box appears with instructions. Open a **new terminal tab**, edit the file with `nano`, save, close, then press **ENTER** in the original terminal to continue.

### Pause 1 — `/etc/netplan/network.yaml`

```bash
sudo nano /etc/netplan/network.yaml
```

| Field | Value |
|-------|-------|
| `eth0` address | `172.20.112.253/20` |
| Gateway | `172.20.112.1` |
| DNS | **Replace `172.16.X.X` with your real DNS IP** |
| `eth1` | No IP address (leave blank) |

### Pause 2 — `/etc/kolla/globals.yml`

```bash
sudo nano /etc/kolla/globals.yml
```

| Field | Default | Notes |
|-------|---------|-------|
| `kolla_internal_vip_address` | `172.20.112.251` | Must be a **free** IP on your network |
| `network_interface` | `eth0` | Management NIC |
| `neutron_external_interface` | `eth1` | External NIC — must have **no IP** |
| `enable_cinder` | `yes` | Block storage |
| `enable_cinder_backend_lvm` | `yes` | LVM on /dev/sdb |

Add any extra `enable_*` services you want here before continuing.

### Pause 3 — `~/init-runonce`

```bash
nano ~/init-runonce
```

| Variable | Pre-patched value |
|----------|-------------------|
| `EXT_NET_CIDR` | `172.20.112.0/20` |
| `EXT_NET_RANGE` | `start=172.20.112.200,end=172.20.112.229` |
| `EXT_NET_GATEWAY` | `172.20.112.1` |

Adjust the demo network (`DEMO_NET_CIDR`, `DEMO_NET_GATEWAY`) if needed, then press **ENTER** to run it.

---

## What the script does (all steps)

| # | Step | Description |
|---|------|-------------|
| 1 | Passwordless sudo | Adds your user to `/etc/sudoers.d/` |
| 2 | KVM check | Installs `cpu-checker`, loads `kvm_intel` with `nested=1` |
| 3 | ✏️ **Netplan** | Writes `network.yaml`, pauses for your edit, then applies it |
| 4 | LVM setup | Creates `cinder-volumes` VG on `/dev/sdb` (50 GB SSD) |
| 5 | System update | `apt update && apt upgrade` + all build dependencies |
| 6 | Python venv | Creates `~/kolla-venv` |
| 7 | Kolla-Ansible | Installs from `opendev.org` branch `stable/2025.2` |
| 8 | Kolla configs | Copies example configs to `/etc/kolla/` |
| 9 | Inventory | Copies `all-in-one` inventory to `~/all-in-one` |
| 10 | install-deps | Runs `kolla-ansible install-deps` |
| 11 | Passwords | Runs `kolla-genpwd`, saves admin password to `~/keystone_admin_password.txt` |
| 12 | ✏️ **globals.yml** | Writes config, pauses for your edit |
| 13 | VIP ping check | Confirms `172.20.112.251` is not already in use |
| 14 | bootstrap-servers | Prepares the host for OpenStack |
| 15 | prechecks | Validates all requirements before deploy |
| 16 | **deploy** ☕ | Deploys all OpenStack containers (~20–40 min) |
| 17 | OpenStack CLI | Installs `python-openstackclient` |
| 18 | post-deploy | Finalises deployment, generates `clouds.yaml` |
| 19 | clouds.yaml | Copies to `~/.config/openstack/` |
| 20 | .bashrc | Adds `OS_CLOUD=kolla-admin` + venv auto-activation |
| 21 | Docker group | Adds user to `docker` group |
| 22 | ✏️ **init-runonce** | Patches external network settings, pauses for your edit |
| 23 | init-runonce | Creates demo network, router, floating IPs, CirrOS image |
| 24 | Verification | Lists all services, agents, containers |

---

## Network layout

```
172.20.112.0/20  (172.20.112.0 – 172.20.127.255)

  eth0  172.20.112.253   ← management / API
  VIP   172.20.112.251   ← Kolla internal VIP (must be free)
  GW    172.20.112.1

  Floating IPs pool:  172.20.112.200 – 172.20.112.229
  eth1  (no IP)       ← Neutron external bridge
```

---

## After deployment

```bash
# Re-login (or: newgrp docker) to pick up docker group
ssh openstack@172.20.112.253

# Verify services
openstack service list
openstack compute service list
openstack network agent list
openstack volume service list
docker ps

# Horizon dashboard
http://172.20.112.251
# User: admin
# Password: contents of ~/keystone_admin_password.txt
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| ISO not found by `create_vm.ps1` | Script will prompt you to type the full path manually |
| `kvm-ok` fails inside VM | On the Hyper-V host run: `Set-VMProcessor -VMName cloudServer -ExposeVirtualizationExtensions $true` then reboot the VM |
| `/dev/sdb` not found | Confirm the 50 GB SSD disk is attached in Hyper-V Manager before running the script |
| SSH drops after netplan apply | Reconnect to the static IP: `ssh openstack@172.20.112.253` |
| VIP `172.20.112.251` in use | Edit `/etc/kolla/globals.yml` at Pause 2 and change `kolla_internal_vip_address` to another free IP |
| `prechecks` fail | Read the Ansible output — most issues are fixable without re-running from scratch |
| `deploy` fails mid-way | Re-run `kolla-ansible deploy -i ~/all-in-one` — it is idempotent |
| `init-runonce` fails | Ensure `openstack service list` works first; check the floating IP range doesn't conflict with existing hosts |
