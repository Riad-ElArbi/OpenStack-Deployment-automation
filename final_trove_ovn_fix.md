# final_trove_ovn_fix.md
## Trove DBaaS on OpenStack 2025.2 — Complete Deployment & Fix Guide
### From Zero to a Working MySQL Instance on a Nested Hypervisor with OVN

---

> **Role:** Senior DevOps / OpenStack Infrastructure Engineer
> **Environment:** OpenStack 2025.2 (Kolla-Ansible All-in-One) — Hyper-V → KVM — OVN backend
> **Status:** ✅ FULLY RESOLVED — MySQL accessible from OpenStack host

---

## Table of Contents

1. [Environment](#1-environment)
2. [Architecture](#2-architecture)
3. [Pre-Deployment Checklist](#3-pre-deployment-checklist)
4. [Deployment Steps](#4-deployment-steps)
5. [Problem 1 — HAProxy Missing RabbitMQ Port 5672](#5-problem-1--haproxy-missing-rabbitmq-port-5672)
6. [Problem 2 — Nova force_raw_images](#6-problem-2--nova-force_raw_images)
7. [Problem 3 — Guest Image Has No Config File](#7-problem-3--guest-image-has-no-config-file)
8. [Problem 4 — CLI `datastore version set` Broken](#8-problem-4--cli-datastore-version-set-broken)
9. [Problem 5 — socat and dnsmasq Not Persistent](#9-problem-5--socat-and-dnsmasq-not-persistent)
10. [Problem 6 — OVN neutron_pg_drop Blocks All Traffic](#10-problem-6--ovn-neutron_pg_drop-blocks-all-traffic)
11. [Problem 7 — MySQL Takes 7+ Minutes on Nested Hypervisor](#11-problem-7--mysql-takes-7-minutes-on-nested-hypervisor)
12. [Problem 8 — os_admin MySQL User Never Created](#12-problem-8--os_admin-mysql-user-never-created)
13. [Problem 9 — Operating Status Stuck at ERROR](#13-problem-9--operating-status-stuck-at-error)
14. [Problem 10 — MySQL Not Accessible from OpenStack Host](#14-problem-10--mysql-not-accessible-from-openstack-host)
    - [Root cause analysis](#root-cause-analysis)
    - [What was tried and failed](#what-was-tried-and-failed)
    - [The fix — OVS internal port on the host](#the-fix--ovs-internal-port-on-the-host)
15. [Prevention — Checklist for Every New Instance](#15-prevention--checklist-for-every-new-instance)
16. [Automated Instance Creation Script](#16-automated-instance-creation-script)
17. [Key IDs and Credentials Reference](#17-key-ids-and-credentials-reference)

---

## 1. Environment

| Parameter | Value |
|-----------|-------|
| OpenStack version | 2025.2 |
| Deployment method | Kolla-Ansible All-in-One |
| OS | Ubuntu 24.04 |
| Hypervisor | Hyper-V VM running KVM (nested) |
| Network backend | OVN |
| Host IP | `172.21.208.100` |
| VIP (HAProxy) | `172.21.208.111` |
| Public network | `192.168.200.0/24` |
| Tenant network (`demo-net`) | `10.0.0.0/24` |
| Trove mgmt network | `10.2.0.0/24` |
| `t-mgmt0` host port IP | `10.2.0.1` |
| `t-mgmt0` MAC | `fa:16:3e:81:68:0c` |
| `t-mgmt0` Neutron port ID | `7169574d-7cf8-430e-8b1f-601860872c3e` |
| Trove mgmt net ID | `7626aceb-e0a3-47e0-b936-9a131081a043` |
| University DNS | `172.16.15.19`, `172.16.15.21` |
| MySQL root password (guest) | `GruSb8EuTm9jgR3TcAMVUH771TDpbjbi0bTP` |
| Trove DB password | `jSNJrTvNtwmc9gENvxxBj7HoMR1wtYBqRfmfV19J` |
| SSH key | `~/trove-ssh-key.pem` |

---

## 2. Architecture

```
172.21.208.0/20 (Hyper-V host / OpenStack control plane)
    └── eth0: 172.21.208.100       (OpenStack host)
    └── t-mgmt0: 10.2.0.1/24      (Trove management network gateway — OVS internal port on br-int)
    └── o-hm0: 10.1.0.146/24      (Octavia health manager)
    └── host-demo0: 10.0.0.105/24 (Host NIC on demo-net — THE FINAL FIX)

10.2.0.0/24 (Trove management network — trove-mgmt-net)
    └── Guest VM ens4: 10.2.0.59  (SSH, guest agent → RabbitMQ)

10.0.0.0/24 (Neutron user network — demo-net)
    └── Docker container "database": 10.0.0.11:3306  (MySQL via docker-hostnic driver)
    └── web-02: 10.0.0.x           (can reach MySQL directly)
    └── host-demo0: 10.0.0.105     (host virtual NIC — added to reach MySQL)
```

### Critical path for ACTIVE status

```
Guest boots
  → agent connects to RabbitMQ at 10.2.0.1:5672 (relayed via socat → 172.21.208.100:5672)
  → taskmanager sends "prepare" RPC
  → agent loads mysql:8.0 Docker image
  → agent starts MySQL container on demo-net via docker-hostnic (gets IP 10.0.0.11)
  → agent connects via socket, runs SELECT 1
  → sends "healthy" heartbeat to conductor
  → instance flips to ACTIVE / HEALTHY
```

Any break in this chain = BUILD timeout = task_id=91 = stuck forever.

### Why t-mgmt0 works with OVN

OVN uses OVS underneath. An OVS internal port on `br-int` with the correct `iface-id` external_id is recognized by OVN as a logical port — identical to how Octavia's `o-hm0` works. No router interface needed; the host port IS the gateway at `10.2.0.1`.

### The docker-hostnic driver (key architectural fact)

Trove's docker plugin uses the `docker-hostnic` driver which gives the MySQL container its own MAC address (`fa:16:3e:bb:85:2b`) and places it directly onto the Neutron `demo-net` network (`10.0.0.0/24`) via a tap interface plugged into OVS. This means:

- The container appears as a **first-class Neutron port** with IP `10.0.0.11`
- The guest VM's kernel **cannot reach** `10.0.0.11` — this is macvlan host isolation (parent cannot reach macvlan child)
- The container is only reachable from within the OVS `demo-net` network

---

## 3. Pre-Deployment Checklist

Run these before starting. Any failure here will cascade into broken Trove.

```bash
# VPN and LB must stay healthy throughout
openstack vpn ipsec site connection list   # Must show: ACTIVE
openstack loadbalancer list                # Must show: ACTIVE, ONLINE
docker ps | grep -E "Exited|unhealthy"    # Must be empty

# Disk space
df -h /                                   # Need at least 20G free

# Passwords present
grep -E "trove_database_password|trove_keystone_password|rabbitmq_password" /etc/kolla/passwords.yml

# IP forwarding
sysctl net.ipv4.ip_forward                # Must be: 1

# rp_filter — MUST be 0 or management packets will be silently dropped
sysctl net.ipv4.conf.all.rp_filter        # Must be: 0
sysctl net.ipv4.conf.default.rp_filter    # Must be: 0
```

If `rp_filter` is not 0, fix it permanently before proceeding:

```bash
sudo tee /etc/sysctl.d/99-trove-mgmt.conf << 'EOF'
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
sudo sysctl --system
```

---

## 4. Deployment Steps

### Step 1 — globals.yml

```bash
sudo nano /etc/kolla/globals.yml
# Add:
# enable_trove: "yes"
# enable_horizon_trove: "{{ enable_trove | bool }}"
```

### Step 2 — Pull and deploy

```bash
kolla-ansible pull -i ~/all-in-one --tags trove
kolla-ansible deploy -i ~/all-in-one --tags trove,horizon,haproxy
# Expected: ok=141 changed=30 unreachable=0 failed=0
docker ps | grep trove   # trove_api, trove_conductor, trove_taskmanager — all Up
```

### Step 3 — Install Trove CLI

```bash
pip install python-troveclient --break-system-packages
```

### Step 4 — Create security group and keypair

> **Critical:** The keypair MUST be created under the `trove` service user, not `admin`. Nova validates keypairs against the calling user. If it's under `admin`, the taskmanager (which calls Nova as `trove`) cannot see it and instance creation fails with `Invalid key_name`.

```bash
source /etc/kolla/admin-openrc.sh

# Security group (under admin project is fine)
openstack security group create trove-sec-grp \
  --description "Trove database instance SG"

TROVE_SG_ID=$(openstack security group show trove-sec-grp -f value -c id)

openstack security group rule create $TROVE_SG_ID --protocol icmp --ethertype IPv4
openstack security group rule create $TROVE_SG_ID --protocol tcp --dst-port 22
openstack security group rule create $TROVE_SG_ID --protocol tcp --dst-port 3306
openstack security group rule create $TROVE_SG_ID --protocol tcp --remote-ip 10.2.0.0/24

# Keypair — MUST be under trove service user
TROVE_PASS=$(grep "^trove_keystone_password" /etc/kolla/passwords.yml | awk '{print $2}')

openstack keypair create trove-ssh-key \
  --os-username trove \
  --os-password $TROVE_PASS \
  --os-project-name service \
  --os-project-domain-name Default \
  --os-user-domain-name Default > ~/trove-ssh-key.pem

chmod 600 ~/trove-ssh-key.pem
head -1 ~/trove-ssh-key.pem   # Must show: -----BEGIN OPENSSH PRIVATE KEY-----
```

### Step 5 — Trove config files and reconfigure

```bash
RABBIT_PASS=$(grep "^rabbitmq_password" /etc/kolla/passwords.yml | awk '{print $2}')
TROVE_NET_ID=$(openstack network show trove-mgmt-net -f value -c id)

sudo mkdir -p /etc/kolla/config/trove

sudo tee /etc/kolla/config/trove.conf << EOF
[DEFAULT]
management_networks = ${TROVE_NET_ID}
nova_keypair = trove-ssh-key
management_security_groups = ${TROVE_SG_ID}
EOF

sudo tee /etc/kolla/config/trove/trove-guestagent.conf << EOF
[DEFAULT]
transport_url = rabbit://openstack:${RABBIT_PASS}@10.2.0.1:5672//
control_exchange = trove
root_grant = ALL
root_grant_option = True
state_change_wait_time = 600
state_healthy_counts = 2
debug = True

[mysql]
usage_timeout = 900

[oslo_messaging_rabbit]
heartbeat_in_pthread = false
amqp_durable_queues = true
rabbit_quorum_queue = true
EOF

kolla-ansible reconfigure -i ~/all-in-one --tags trove
```

### Step 6 — Guest image preparation and upload

```bash
cd ~
wget https://tarballs.opendev.org/openstack/trove/images/trove-master-guest-ubuntu-jammy.qcow2
sudo apt install -y libguestfs-tools

# Fix 1: socket path mismatch
sudo virt-customize -a ~/trove-master-guest-ubuntu-jammy.qcow2 \
  --run-command "find /opt /usr -name constants.py -path '*/trove/*' 2>/dev/null \
    | xargs grep -l 'MYSQL_HOST_SOCKET_PATH' 2>/dev/null \
    | xargs sed -i 's|MYSQL_HOST_SOCKET_PATH = \"/var/lib/mysqld\"|MYSQL_HOST_SOCKET_PATH = \"/var/run/mysqld\"|' \
    2>/dev/null; true"

# Fix 2: bind mount for socket directory
sudo virt-customize -a ~/trove-master-guest-ubuntu-jammy.qcow2 \
  --run-command "grep -q '/var/lib/mysqld /var/run/mysqld' /etc/fstab \
    || echo '/var/lib/mysqld /var/run/mysqld none bind 0 0' >> /etc/fstab"

# Fix 3: bake timeout config so it overrides taskmanager defaults
sudo virt-customize -a ~/trove-master-guest-ubuntu-jammy.qcow2 \
  --run-command "mkdir -p /etc/trove/conf.d && \
    cat > /etc/trove/conf.d/trove-guestagent.conf << 'EOF'
[DEFAULT]
state_change_wait_time = 600
state_healthy_counts = 2

[mysql]
usage_timeout = 900
EOF"

# Fix 4: patch transport_url at boot (cloud-init overwrites it)
sudo virt-customize -a ~/trove-master-guest-ubuntu-jammy.qcow2 \
  --run-command "cat > /etc/systemd/system/trove-fix.service << 'EOF'
[Unit]
Description=Fix Trove guest agent config
Before=guest-agent.service
After=cloud-init.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c \"sed -i s/172\\.21\\.208\\.100/10.2.0.1/g /etc/trove/conf.d/trove-guestagent.conf; sed -i s/172\\.21\\.208\\.111/10.2.0.1/g /etc/trove/conf.d/trove-guestagent.conf\"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable trove-fix.service"

# Fix 5: ens4 DHCP (cloud-init DataSourceNone skips it)
sudo virt-customize -a ~/trove-master-guest-ubuntu-jammy.qcow2 \
  --run-command "cat > /etc/netplan/60-ens4.yaml << 'EOF'
network:
  version: 2
  ethernets:
    ens4:
      dhcp4: true
      dhcp4-overrides:
        use-routes: false
EOF"

# Fix 6: silence groupadd/useradd duplicate errors on agent restart
sudo virt-customize -a ~/trove-master-guest-ubuntu-jammy.qcow2 \
  --run-command "OSFILE=\$(find /opt -name operating_system.py -path '*/trove/*' 2>/dev/null | head -1); \
    [ -n \"\$OSFILE\" ] && sed -i 's/except exception.ProcessExecutionError as err:/except exception.ProcessExecutionError:/g' \$OSFILE; \
    sed -i '/if .already exists. not in err.stderr/,/raise/d' \$OSFILE; true"

# Fix 7: skip docker pull (no internet on guest)
sudo virt-customize -a ~/trove-master-guest-ubuntu-jammy.qcow2 \
  --run-command "DFILE=\$(find /opt -name docker.py -path '*/trove/guestagent/utils/*' 2>/dev/null | head -1); \
    [ -n \"\$DFILE\" ] && sed -i 's/client.pull(image)/#client.pull(image)/' \$DFILE; true"

# Upload image
openstack image create "Trove-MySQL-v2" \
  --disk-format qcow2 \
  --container-format bare \
  --public \
  --tag trove \
  --tag mysql \
  --file ~/trove-master-guest-ubuntu-jammy.qcow2

openstack image show Trove-MySQL-v2 -c status -c id
```

### Step 7 — Register datastore

```bash
openstack datastore version create 8.0 mysql mysql "" \
  --image-tags trove,mysql \
  --active \
  --default \
  --version-number 8.0

# Verify
openstack datastore list
openstack datastore version list mysql
```

### Step 8 — Pre-load mysql:8.0 into the guest (every new instance)

Since the guest has no internet access, the Docker image must be loaded manually after each new instance boots:

```bash
# Pull on host (once)
sudo docker pull mysql:8.0

# After instance boots and gets its mgmt IP (e.g. 10.2.0.59):
sudo docker save mysql:8.0 | ssh -i ~/trove-ssh-key.pem ubuntu@10.2.0.59 "sudo docker load"
```

### Step 9 — Create a test instance

```bash
openstack role add --project service --user admin admin

openstack flavor create db.small \
  --vcpus 1 --ram 1024 --disk 10 --public 2>/dev/null || true

DEMO_NET_ID=$(openstack network show demo-net -f value -c id)

openstack database instance create test-mysql \
  --flavor db.small \
  --size 5 \
  --nic net-id=${DEMO_NET_ID} \
  --datastore mysql \
  --datastore-version 8.0

watch openstack database instance list
```

---

## 5. Problem 1 — HAProxy Missing RabbitMQ Port 5672

**What happened:** Guest agent started, tried to connect to RabbitMQ at `172.21.208.111:5672` (VIP), got connection refused. HAProxy only had the management frontend (port 15672), not the AMQP port (5672).

**Why:** The default Kolla HAProxy config for RabbitMQ does not include the AMQP port. It must be added manually.

**Fix:**

```bash
sudo tee /etc/kolla/haproxy/services.d/rabbitmq.cfg << 'EOF'
frontend rabbitmq_management_front
    mode http
    bind 172.21.208.111:15672
    default_backend rabbitmq_management_back

backend rabbitmq_management_back
    mode http
    server stable 172.21.208.100:15672 check inter 2000 rise 2 fall 5

frontend rabbitmq_front
    bind 172.21.208.111:5672
    mode tcp
    option tcplog
    default_backend rabbitmq_back

backend rabbitmq_back
    mode tcp
    option tcpka
    server stable 172.21.208.100:5672 check inter 2000 rise 2 fall 3
EOF
docker restart haproxy
nc -zv 172.21.208.111 5672   # Must succeed
```

---

## 6. Problem 2 — Nova force_raw_images

**What happened:** Nova rejected the qcow2 guest image during instance creation, trying to convert it to raw format which failed on the nested hypervisor.

**Why:** The default Nova config converts qcow2 images to raw before attaching. On nested KVM, this is slow and often fails.

**Fix:**

```bash
sudo mkdir -p /etc/kolla/config/nova/
sudo tee /etc/kolla/config/nova/nova-compute.conf << 'EOF'
[libvirt]
virt_type = kvm
cpu_mode = host-passthrough

[DEFAULT]
vif_plugging_is_fatal = false
vif_plugging_timeout = 0
force_raw_images = false
EOF
kolla-ansible reconfigure -i ~/all-in-one --tags nova
docker exec nova_compute grep force_raw /etc/nova/nova.conf
# Must show: force_raw_images = false
```

---

## 7. Problem 3 — Guest Image Has No Config File

**What happened:**

```bash
sudo virt-customize -a /tmp/trove-guest.qcow2 \
  --run-command "grep -q 'state_change_wait_time' /etc/trove/conf.d/trove-guestagent.conf || ..."
# Error: sed: can't read /etc/trove/conf.d/trove-guestagent.conf: No such file or directory
```

**Why:** The config file does not exist in the base image. The taskmanager generates it at runtime and injects it into the guest via cloud-init/config drive. The directory exists but the file is empty on first boot — cloud-init then overwrites it.

**Fix:** Create the file from scratch, and also add a systemd unit to re-patch it after cloud-init runs (since cloud-init runs after the file is created on boot and overwrites it):

```bash
# Bake initial config into image
sudo virt-customize -a /tmp/trove-guest.qcow2 \
  --run-command "mkdir -p /etc/trove/conf.d && \
    cat > /etc/trove/conf.d/trove-guestagent.conf << 'EOF'
[DEFAULT]
state_change_wait_time = 600
state_healthy_counts = 2

[mysql]
usage_timeout = 900
EOF"

# Verify it landed
sudo virt-cat -a /tmp/trove-guest.qcow2 /etc/trove/conf.d/trove-guestagent.conf
```

---

## 8. Problem 4 — CLI `datastore version set` Broken

**What happened:**

```bash
openstack datastore version set mysql "8.0" --image "$NEW_IMAGE_ID"
# ERROR: unrecognized arguments: 8.0
```

**Why:** The OSC troveclient plugin does not accept the datastore name as a positional argument. It requires the version UUID.

**Fix:**

```bash
DS_VERSION_ID=$(openstack datastore version list mysql -f value -c ID | head -1)
openstack datastore version set "$DS_VERSION_ID" --image "$NEW_IMAGE_ID"

# Verify via direct API (CLI show is also broken)
PROJECT_ID=$(openstack project show admin -f value -c id)
TROVE_TOKEN=$(openstack token issue -f value -c id)
curl -s "http://172.21.208.111:8779/v1.0/${PROJECT_ID}/datastores/mysql/versions/${DS_VERSION_ID}" \
  -H "X-Auth-Token: $TROVE_TOKEN" | python3 -m json.tool | grep image
```

---

## 9. Problem 5 — socat and dnsmasq Not Persistent

**What happened:** The RabbitMQ relay (`socat`) and DNS relay (`dnsmasq`) were started as background `&` processes. They died on session logout and after reboot.

**Why:** Background shell processes have no restart policy and don't survive reboots.

**Why socat is needed:** The `trove-mgmt-net` is an isolated OVN logical switch. OVN drops all packets from the guest destined outside `10.2.0.0/24`. The only path is via `t-mgmt0` at `10.2.0.1`. RabbitMQ listens on `172.21.208.100:5672`. A relay on `10.2.0.1:5672` bridges the two.

**Why dnsmasq is needed:** The guest has no direct access to the university DNS servers (`172.16.15.19`, `172.16.15.21`). Docker needs DNS to resolve image names. A DNS relay on `10.2.0.1:53` forwards queries to the real DNS.

**Fix — convert both to systemd services:**

```bash
# RabbitMQ relay
sudo tee /etc/systemd/system/trove-socat.service << 'EOF'
[Unit]
Description=Trove RabbitMQ relay 10.2.0.1:5672 -> 172.21.208.100:5672
After=network.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:5672,bind=10.2.0.1,fork,reuseaddr TCP:172.21.208.100:5672
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# DNS relay
sudo tee /etc/systemd/system/trove-dnsmasq.service << 'EOF'
[Unit]
Description=Trove DNS relay for guest VMs
After=network.target

[Service]
ExecStart=/usr/sbin/dnsmasq --no-daemon --bind-interfaces \
  --listen-address=10.2.0.1 --no-resolv \
  --server=172.16.15.19 --server=172.16.15.21 --port=53
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now trove-socat trove-dnsmasq
sudo systemctl status trove-socat trove-dnsmasq
```

---

## 10. Problem 6 — OVN neutron_pg_drop Blocks All Traffic

**What happened:** Every new Trove instance (both mgmt port and user network port) gets automatically added by OVN to the `neutron_pg_drop` port group. This group has a priority-1001 ACL that drops all IP traffic. The guest agent could not reach RabbitMQ, and the floating IP could not reach MySQL.

**Why:** OVN's default security model adds all new ports to `neutron_pg_drop` as a safe default. Trove does not remove the port automatically.

**Fix — must run immediately after instance creation for BOTH ports:**

```bash
# Remove a port from neutron_pg_drop
remove_from_pg_drop() {
  local PORT_ID=$1
  CURRENT=$(sudo docker exec ovn_northd ovn-nbctl pg-get-ports neutron_pg_drop)
  NEW_LIST=$(echo "$CURRENT" | tr ' ' '\n' | grep -v "$PORT_ID" | tr '\n' ' ')
  sudo docker exec ovn_northd ovn-nbctl pg-set-ports neutron_pg_drop $NEW_LIST
  echo "Removed $PORT_ID from neutron_pg_drop"
}

# Apply to management port
remove_from_pg_drop "22711d6c-f023-41a8-8b3c-94a77944ee65"

# Apply to user network port (demo-net)
remove_from_pg_drop "f82fab8c-4c9a-406f-b85c-65aa13963c65"

# Verify
sudo docker exec ovn_northd ovn-nbctl pg-get-ports neutron_pg_drop | tr ' ' '\n' | grep -E "22711d6c|f82fab8c"
# Must return nothing
```

---

## 11. Problem 7 — MySQL Takes 7+ Minutes on Nested Hypervisor

**What happened:** New instance booted cleanly. Guest agent started and received the `prepare` command. MySQL's full initialization sequence on the nested KVM:

```
09:30:51 — InnoDB initialization started
09:31:50 — InnoDB initialization ended (59 seconds)
09:34:43 — Root user created (~3.5 minutes)
09:37:56 — Temp server started
09:38:42 — Temp server stopped, final boot started
09:38:42 — SECOND InnoDB init started
09:33:43 — Guest agent already gave up (usage_timeout=400s expired)
09:43:xx — MySQL actually ready (agent had been dead for 10 minutes)
```

**Why:** Trove's defaults were designed for bare metal:

| Parameter | Default | Needed on nested KVM |
|-----------|---------|---------------------|
| `state_change_wait_time` | 180s | 600s |
| `mysql.usage_timeout` | 400s | 900s |
| `state_healthy_counts` | 5 | 2 |

**Fix — patch the taskmanager config (permanent, do once):**

```bash
sudo docker exec trove_taskmanager bash -c "
cat >> /etc/trove/trove-guestagent.conf << 'EOF'

[mysql]
usage_timeout = 900

[DEFAULT]
state_change_wait_time = 600
state_healthy_counts = 2
EOF
"
sudo docker restart trove_taskmanager
```

Also bake into the guest image (see Step 6 above, Fix 3) so it takes effect even if the taskmanager config is reset.

---

## 12. Problem 8 — os_admin MySQL User Never Created

**What happened:** After the timeout issue, the instance was manually forced to ACTIVE via a direct DB update. However, MySQL was running but had no Trove admin user — `prepare` had timed out before the user creation step.

**Why:** The guest agent's `do_prepare()` creates `os_admin` as part of the prepare sequence. If the sequence times out before that step, the user is never created and all subsequent Trove API operations (create database, create user, reset password) silently fail.

**Fix — create the user manually:**

```bash
ssh -i ~/trove-ssh-key.pem ubuntu@10.2.0.59 \
  "sudo docker exec -it database mysql -u root -p'GruSb8EuTm9jgR3TcAMVUH771TDpbjbi0bTP' -e \"
CREATE USER 'os_admin'@'localhost' IDENTIFIED BY 'os_admin_password';
GRANT ALL PRIVILEGES ON *.* TO 'os_admin'@'localhost' WITH GRANT OPTION;
CREATE USER 'os_admin'@'%' IDENTIFIED BY 'os_admin_password';
GRANT ALL PRIVILEGES ON *.* TO 'os_admin'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;\""

# Verify
ssh -i ~/trove-ssh-key.pem ubuntu@10.2.0.59 \
  "sudo docker exec database mysql -u os_admin -pos_admin_password -e 'SELECT 1'"
```

---

## 13. Problem 9 — Operating Status Stuck at ERROR

**What happened:** After manually fixing MySQL and the `os_admin` user, the Trove API still showed `operating_status: ERROR`. The `service_statuses` table had a stale row from the original timeout event (`guestagent error`, timestamp `2026-05-19 09:33:54`).

**Why:** The conductor updates `service_statuses` based on heartbeats from the guest agent. Since the agent's `prepare_completed` flag was `False` (the sentinel file `.guestagent.prepare.end` was missing), the agent was skipping all status checks.

**Fix — in this exact order:**

```bash
# Step 1: Touch the sentinel file so the agent starts reporting real status
ssh -i ~/trove-ssh-key.pem ubuntu@10.2.0.59 \
  "sudo touch /opt/trove-guestagent/.guestagent.prepare.end"

# Step 2: Wait 35 seconds for the agent's next poll cycle
sleep 35
openstack database instance show f9af738a-d328-4979-b409-45f072ba4559 \
  -f value -c status -c operating_status
# Expected: ACTIVE / HEALTHY

# Step 3: If the agent doesn't self-correct, force it via direct DB update
TROVE_DB=$(sudo docker ps --format '{{.Names}}' | grep -i maria | head -1)
sudo docker exec -it $TROVE_DB mariadb \
  -u trove -p"jSNJrTvNtwmc9gENvxxBj7HoMR1wtYBqRfmfV19J" trove \
  -e "UPDATE service_statuses
      SET status_id=33,
          status_description='HEALTHY',
          updated_at=NOW()
      WHERE instance_id='f9af738a-d328-4979-b409-45f072ba4559';"
# Note: status_id=33 = 0x21 = HEALTHY in Trove's ServiceStatus enum
```

---

## 14. Problem 10 — MySQL Not Accessible from OpenStack Host

This was the most complex problem and required the most investigation. The full journey is documented here so it is never repeated.

### Root cause analysis

The MySQL container lives on `demo-net` (`10.0.0.0/24`) via the `docker-hostnic` driver. This network is a Neutron OVN overlay, only reachable through OVS on the OpenStack host. The host had no interface registered as a logical port on `demo-net`, so OVN had no path to deliver packets to it.

**Three compounding reasons packets couldn't reach `10.0.0.11`:**

1. **No route to `10.0.0.0/24` from the host** — the host routing table had no entry for that subnet; packets went to the default gateway (`172.21.208.1`) and disappeared into the VPN/physical network.

2. **macvlan host isolation** — the guest VM (`10.2.0.59`) physically cannot reach the MySQL container (`10.0.0.11`) because `docker-hostnic` is a macvlan-like driver. Macvlan children are unreachable from the parent interface by design. The VM's kernel returns `[Errno 101] Network is unreachable` for `10.0.0.11`.

3. **OVN port security** — even after adding an IP to `br-int`, packets sourced from an unregistered MAC/IP were dropped by OVN's port security pipeline before reaching the container.

### What was tried and failed

| Attempt | Why it failed |
|---------|---------------|
| iptables DNAT on the guest VM | VM can't reach `10.0.0.11` — macvlan isolation |
| Python TCP relay on the guest VM | Same root cause — `[Errno 101] Network is unreachable` |
| `sudo ip addr add 10.0.0.250/24 dev br-int` + route | OVN drops packets from unregistered logical port — no MAC/IP in port security |
| Relay in `ovnmeta-64506fef` namespace binding to `0.0.0.0` | Namespace is not routable from the host's default namespace |
| Docker `-p 3306:3306` port binding on the container | `docker-hostnic` driver bypasses Docker's userland proxy — `-p` silently does nothing |
| Adding container to Docker `bridge` network | No default bridge network exists on this host (only `docker-hostnic`, `host`, `none`) |
| Python relay in Docker `host` network container | `mysql:8.0` container (Rocky Linux) has no `python3` in PATH |
| Floating IP (`192.168.200.151`) via Neutron router | Packet reached the VM but a leftover `/tmp/mysql_relay.py` was occupying port 3306 on the VM and swallowing connections without forwarding. After killing it, the floating IP path also failed because nothing was listening on `10.0.0.11:3306` from outside (docker-hostnic + no port binding). |
| `neutron_pg_drop` removal for floating IP port | Necessary but not sufficient alone |

### The fix — OVS internal port on the host

The correct solution is to register the OpenStack host itself as a proper Neutron logical port on `demo-net`. This gives the host a real OVN-registered interface on `10.0.0.0/24` with a proper MAC/IP binding that OVN recognizes and routes to.

```bash
# Step 1: Create a Neutron port on demo-net for the host
openstack port create --network demo-net openstack-host-demo-port

# Step 2: Get the assigned details
PORT_ID=$(openstack port show openstack-host-demo-port -f value -c id)
MAC=$(openstack port show openstack-host-demo-port -f value -c mac_address)
IP=$(openstack port show openstack-host-demo-port -f value -c fixed_ips | grep -oP '10\.0\.0\.\d+')

echo "Port: $PORT_ID  MAC: $MAC  IP: $IP"
# Example: Port: 40234040-504e-4cb3-af5c-14dff43bbfee  MAC: fa:16:3e:2a:a7:5c  IP: 10.0.0.105

# Step 3: Create an OVS internal port bound to this Neutron port
sudo ovs-vsctl add-port br-int host-demo0 \
  -- set interface host-demo0 type=internal \
     external_ids:iface-id=$PORT_ID \
     external_ids:iface-status=active \
     external_ids:attached-mac=$MAC

# Step 4: Assign the IP and MAC to the new interface
sudo ip link set host-demo0 address $MAC
sudo ip addr add $IP/24 dev host-demo0
sudo ip link set host-demo0 up

# Step 5: Remove the new port from neutron_pg_drop
CURRENT=$(sudo docker exec ovn_northd ovn-nbctl pg-get-ports neutron_pg_drop)
NEW_LIST=$(echo "$CURRENT" | tr ' ' '\n' | grep -v "$PORT_ID" | tr '\n' ' ')
sudo docker exec ovn_northd ovn-nbctl pg-set-ports neutron_pg_drop $NEW_LIST

# Step 6: Verify reachability
ping -c 2 10.0.0.11
# Expected: 0% packet loss

# Step 7: Connect to MySQL
mysql -h 10.0.0.11 -u riad -p123 testdb
# Expected: Welcome to the MySQL monitor.
```

**Make the OVS port persistent across reboots:**

```bash
sudo tee /etc/systemd/system/host-demo0.service << EOF
[Unit]
Description=Add host-demo0 OVS port for demo-net access
After=openvswitch.service ovsdb-server.service network.target
Wants=openvswitch.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  ovs-vsctl --may-exist add-port br-int host-demo0 \
    -- set interface host-demo0 type=internal \
       external_ids:iface-id=${PORT_ID} \
       external_ids:iface-status=active \
       external_ids:attached-mac=${MAC}; \
  ip link set host-demo0 address ${MAC}; \
  ip addr add ${IP}/24 dev host-demo0 2>/dev/null || true; \
  ip link set host-demo0 up'

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now host-demo0.service
```

**Why this works:** By creating an OVS internal port with the correct `iface-id` external_id matching a real Neutron port, OVN binds the port to the `openstack` chassis and programs the full forwarding pipeline for it — including ARP, MAC learning, and security group ACLs. The host becomes a first-class citizen of `demo-net`, identical to how `web-02` instances reach MySQL.

### Final network topology (working state)

| Path | Works | Why |
|------|-------|-----|
| `web-02` (`10.0.0.x`) → `10.0.0.11:3306` | ✅ | Same Neutron network |
| OpenStack host (`host-demo0`, `10.0.0.105`) → `10.0.0.11:3306` | ✅ | OVS internal port registered as Neutron logical port |
| OpenStack host (`172.21.208.100`) → `10.0.0.11:3306` | ❌ | No route to OVN overlay from physical network |
| Guest VM (`10.2.0.59`) → `10.0.0.11:3306` | ❌ | Macvlan host isolation — fundamental Linux limitation |
| Relay on guest VM → `10.0.0.11` | ❌ | Same macvlan isolation |
| Floating IP (`192.168.200.151`) → `10.0.0.11:3306` | ⚠️ | Works IF nothing occupies port 3306 on VM AND container has port binding — complex, avoid |

---

## 15. Prevention — Checklist for Every New Instance

These steps **must** run for every new Trove instance to prevent all of the above:

```bash
#!/bin/bash
# Run this immediately after creating a new Trove instance

INSTANCE_ID=$1   # e.g. f9af738a-d328-4979-b409-45f072ba4559
MGMT_NET_ID=$(openstack network show trove-mgmt-net -f value -c id)
DEMO_NET_ID=$(openstack network show demo-net -f value -c id)

echo "=== Waiting for instance ports to appear ==="
sleep 30

# Get the two ports
MGMT_PORT=$(openstack port list --server $(openstack database instance show $INSTANCE_ID -f value -c server_id) \
  --network $MGMT_NET_ID -f value -c ID)
USER_PORT=$(openstack port list --server $(openstack database instance show $INSTANCE_ID -f value -c server_id) \
  --network $DEMO_NET_ID -f value -c ID)

echo "Mgmt port: $MGMT_PORT"
echo "User port: $USER_PORT"

# Remove both from neutron_pg_drop
remove_from_pg_drop() {
  local PORT_ID=$1
  CURRENT=$(sudo docker exec ovn_northd ovn-nbctl pg-get-ports neutron_pg_drop)
  NEW_LIST=$(echo "$CURRENT" | tr ' ' '\n' | grep -v "$PORT_ID" | tr '\n' ' ')
  sudo docker exec ovn_northd ovn-nbctl pg-set-ports neutron_pg_drop $NEW_LIST
  echo "Removed $PORT_ID from neutron_pg_drop"
}

remove_from_pg_drop "$MGMT_PORT"
remove_from_pg_drop "$USER_PORT"

echo "=== OVN fix applied. Monitor instance: ==="
watch -n 15 "openstack database instance show $INSTANCE_ID | grep -E 'status|operating'"
```

---

## 16. Automated Instance Creation Script

```bash
#!/bin/bash
# Usage: ./create_trove_instance.sh <instance-name>
# Handles OVN neutron_pg_drop fix automatically in parallel.

set -e
INSTANCE_NAME=${1:-test-mysql}
DEMO_NET_ID=$(openstack network show demo-net -f value -c id)
MGMT_NET_ID=$(openstack network show trove-mgmt-net -f value -c id)

# Snapshot existing mgmt ports before launch
EXISTING_PORTS=$(openstack port list --network $MGMT_NET_ID -f value -c ID)

# Launch the instance in background
openstack database instance create $INSTANCE_NAME \
  --flavor db.small --size 5 \
  --nic net-id=$DEMO_NET_ID \
  --datastore mysql --datastore-version 8.0 &

# Poll for new mgmt port and remove from neutron_pg_drop
echo "Polling for new mgmt port..."
while true; do
  NEW_PORT=$(openstack port list --network $MGMT_NET_ID -f value -c ID 2>/dev/null | \
    grep -v -F "$EXISTING_PORTS" | head -1)
  [ -n "$NEW_PORT" ] && break
  sleep 5
done

echo "Port found: $NEW_PORT — removing from neutron_pg_drop"
CURRENT=$(sudo docker exec ovn_northd ovn-nbctl pg-get-ports neutron_pg_drop)
NEW_LIST=$(echo "$CURRENT" | tr ' ' '\n' | grep -v "$NEW_PORT" | tr '\n' ' ')
sudo docker exec ovn_northd ovn-nbctl pg-set-ports neutron_pg_drop $NEW_LIST
echo "OVN fix applied."

# Load MySQL image into guest once it has an mgmt IP
echo "Waiting for guest to get mgmt IP..."
while true; do
  GUEST_IP=$(openstack port show $NEW_PORT -f value -c fixed_ips | grep -oP '10\.2\.0\.\d+')
  [ -n "$GUEST_IP" ] && break
  sleep 10
done

echo "Loading mysql:8.0 into guest at $GUEST_IP..."
sudo docker save mysql:8.0 | ssh -i ~/trove-ssh-key.pem -o StrictHostKeyChecking=no \
  ubuntu@$GUEST_IP "sudo docker load"
echo "Image loaded."

# Monitor until ready
watch -n 15 "openstack database instance list"
```

---

## 17. Key IDs and Credentials Reference

| Resource | Value |
|----------|-------|
| Current instance ID | `f9af738a-d328-4979-b409-45f072ba4559` |
| Nova VM ID | `dfe78ee3-a5aa-450f-a9dc-1d05b341bcf4` |
| Guest image ID | `a5c19e96-770e-4761-8169-6570368dcfea` |
| Datastore version ID | `00724dd7-91ce-40f9-89fd-ec1d3b1956ad` |
| Mgmt port ID | `22711d6c-f023-41a8-8b3c-94a77944ee65` |
| User network port ID | `f82fab8c-4c9a-406f-b85c-65aa13963c65` |
| Host demo-net port ID | `40234040-504e-4cb3-af5c-14dff43bbfee` |
| Host demo-net IP | `10.0.0.105` |
| Guest mgmt IP | `10.2.0.59` |
| Guest user network IP | `10.0.0.11` (MySQL) |
| Floating IP | `192.168.200.151` |
| Trove DB password | `jSNJrTvNtwmc9gENvxxBj7HoMR1wtYBqRfmfV19J` |
| MySQL root password | `GruSb8EuTm9jgR3TcAMVUH771TDpbjbi0bTP` |
| RabbitMQ password | `f3AjGtemMYfDokHhPQ3NSiO5mmrmYc3Qbzn46DVT` |
| Trove Keystone password | `VST5RwuL0n302cI3mW1zNSmw6MxagYxz9JK0bXxJ` |
| SSH key | `~/trove-ssh-key.pem` |

---

## Persistence Summary

| Component | Method | Survives reboot | Survives container recreate |
|-----------|--------|-----------------|----------------------------|
| `t-mgmt0` interface | systemd `trove-t-mgmt0.service` | ✅ | ✅ |
| RabbitMQ relay (socat) | systemd `trove-socat.service` | ✅ | ✅ |
| DNS relay (dnsmasq) | systemd `trove-dnsmasq.service` | ✅ | ✅ |
| `host-demo0` OVS port | systemd `host-demo0.service` | ✅ | ✅ |
| `rp_filter=0` | `/etc/sysctl.d/99-trove-mgmt.conf` | ✅ | ✅ |
| HAProxy rabbitmq.cfg | `/etc/kolla/haproxy/services.d/` | ✅ | ✅ |
| Nova force_raw_images | `/etc/kolla/config/nova/` | ✅ | ✅ |
| Trove config overrides | `/etc/kolla/config/trove/` | ✅ | ✅ |
| VPN neutron patches | Container overlay filesystem | ❌ | ❌ |

> **VPN patches are NOT persistent.** If any neutron container is recreated (not just restarted), the patches must be reapplied. To make permanent: `docker commit neutron_rpc_server neutron-server-patched:2025.2`

---

*Every command in this document was executed in production. Every error was real.*
*The nested hypervisor is hostile to Trove's assumptions. Now you know all of them.*
