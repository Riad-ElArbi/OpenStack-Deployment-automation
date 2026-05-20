# OpenStack 2025.2 — Full Deployment Reference
## Kolla-Ansible All-in-One | OVN | Octavia LBaaS | VPNaaS | Ubuntu 24.04

> **Status:** Production-verified single-node deployment, May 2026.
> All bugs documented here were encountered and resolved during live deployment.

---

## Table of Contents

1. [Environment](#1-environment)
2. [Architecture Overview](#2-architecture-overview)
3. [Part 1 — VPNaaS: Bugs and Fixes](#3-part-1--vpnaas-bugs-and-fixes)
4. [Part 2 — Octavia LBaaS Deployment](#4-part-2--octavia-lbaas-deployment)
5. [Part 3 — Horizon Bugs and Fixes](#5-part-3--horizon-bugs-and-fixes)
6. [Part 4 — Post-Deployment Bugs and Fixes](#6-part-4--post-deployment-bugs-and-fixes)
7. [Part 5 — Known Issues and Fixes](#7-part-5--known-issues-and-fixes)
8. [Part 6 — Operational Reference](#8-part-6--operational-reference)
9. [What NOT To Do](#9-what-not-to-do)

---

## 1. Environment

### Infrastructure

| Parameter            | Value                                    |
|----------------------|------------------------------------------|
| OpenStack Release    | 2025.2                                   |
| Deployment Tool      | Kolla-Ansible (All-in-One)               |
| Host OS              | Ubuntu Server 24.04 (Noble)              |
| Hypervisor           | Hyper-V                                  |
| Host IP              | 172.21.208.100                           |
| VIP Address          | 172.21.208.111                           |
| Neutron Backend      | OVN (`neutron_plugin_agent: "ovn"`)      |
| RAM                  | 20 GB                                    |
| Disk                 | 110 GB (58 GB Docker partition)          |

### Host Networking

| Interface | Role                             | Address                           |
|-----------|----------------------------------|-----------------------------------|
| eth0      | Management / API (Hyper-V Default Switch) | 172.21.208.100             |
| eth1      | External / Provider network      | 192.168.200.x (no IP on host)    |

### OpenStack Networks

| Network          | CIDR                | Purpose                      |
|------------------|---------------------|------------------------------|
| public1          | 192.168.200.0/24    | External / Floating IPs      |
| demo-net         | 10.0.0.0/24         | Tenant workload network      |
| lb-mgmt-net      | 10.1.0.0/24         | Octavia amphora management   |
| Floating IP range| 192.168.200.100–200 | Assigned to tenant instances |
| University/NAT   | 172.16.14.0/24      | Upstream NAT network         |

### Tenant Resources

| Resource             | Tenant IP    | Floating IP       |
|----------------------|--------------|-------------------|
| web-1                | 10.0.0.147   | 192.168.200.134   |
| web-2                | 10.0.0.168   | 192.168.200.178   |
| demo-router (internal)| 10.0.0.1   | —                 |
| demo-router (external)| —          | 192.168.200.180   |

### VPNaaS Topology

| Parameter       | Value                               |
|-----------------|-------------------------------------|
| VPN Gateway IP  | 192.168.200.199 (dedicated OVN port)|
| VyOS WAN        | 192.168.200.50                      |
| VyOS LAN        | 172.21.208.0/20                     |
| Tunnel          | `10.0.0.0/24` ↔ `172.21.208.0/20`  |
| PSK             | `L4BVPN-S3CR3T-2025`               |
| IKE             | IKEv2, AES-256, SHA-256, DH group14 |
| ESP             | AES-256, SHA-256, DH group14        |
| Initiator       | VyOS initiates, OpenStack responds  |

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  Host: Ubuntu 24.04 — 172.21.208.100  (VIP: 172.21.208.111)│
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Kolla Docker Containers                             │   │
│  │  keystone  glance  nova  neutron  horizon  octavia   │   │
│  │  mariadb  rabbitmq  haproxy  memcached  proxysql     │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────┐   ┌──────────────────────────────────┐    │
│  │  eth0        │   │  eth1 (no IP)                    │    │
│  │  172.21.208.100  │  br-ex ↔ public1 192.168.200.0/24│    │
│  └──────────────┘   └──────────────────────────────────┘    │
│                                                              │
│  OVS:  br-int ─── o-hm0 (10.1.0.x) ─── lb-mgmt-net        │
└─────────────────────────────────────────────────────────────┘
          │
          │  IPsec IKEv2 tunnel
          ▼
┌─────────────────────────┐
│  VyOS Router            │
│  WAN: 192.168.200.50    │
│  LAN: 172.21.208.0/20   │
└─────────────────────────┘
```

---

## 3. Part 1 — VPNaaS: Bugs and Fixes

`neutron-vpnaas 27.0.0.0rc2` ships a broken OVN driver. The following bugs were
encountered and patched manually on all four neutron containers.

> ⚠️ **Persistence Warning:** All patches live on live container overlay
> filesystems. They are lost if any neutron container is recreated, the host
> reboots, or `kolla-ansible deploy` is re-run for neutron without `--tags`.
> Always back up patched files before any Kolla operation.

### Backup Patched Files

```bash
sudo mkdir -p /root/vpnaas-patch-backup
sudo docker cp neutron_rpc_server:/var/lib/kolla/venv/lib/python3.12/site-packages/neutron_vpnaas/services/vpn/service_drivers/ovn_ipsec.py \
  /root/vpnaas-patch-backup/ovn_ipsec_patched.py
sudo docker cp neutron_rpc_server:/var/lib/kolla/venv/lib/python3.12/site-packages/neutron_vpnaas/services/vpn/plugin.py \
  /root/vpnaas-patch-backup/plugin_patched.py
```

### Re-apply Patches After Any Reboot or Container Recreation

```bash
for CONTAINER in neutron_server_old neutron_rpc_server neutron_periodic_worker neutron_ovn_maintenance_worker; do
  sudo docker cp /root/vpnaas-patch-backup/ovn_ipsec_patched.py \
    ${CONTAINER}:/var/lib/kolla/venv/lib/python3.12/site-packages/neutron_vpnaas/services/vpn/service_drivers/ovn_ipsec.py
  sudo docker cp /root/vpnaas-patch-backup/plugin_patched.py \
    ${CONTAINER}:/var/lib/kolla/venv/lib/python3.12/site-packages/neutron_vpnaas/services/vpn/plugin.py
  docker exec --user root ${CONTAINER} find \
    /var/lib/kolla/venv/lib/python3.12/site-packages/neutron_vpnaas/ \
    -name "*.pyc" -delete
  docker restart ${CONTAINER}
done
```

---

### BUG 1 — neutron-server HTTP 500 on VPN service create

**Root cause:** `neutron-vpnaas 27.0.0.0rc2` ships an incomplete OVN driver.
Three methods were missing from the plugin.

**Fix A — `schedule_router` missing in `ovn_ipsec.py`:**
Replaced the `schedule_router` call with `socket.gethostname()` since no VPN
agent scheduler exists in OVN all-in-one mode.

**Fix B — Missing gateway DB methods in `plugin.py`:**
Changed the `VPNDriverPlugin` class definition from:
```python
class VPNDriverPlugin(VPNPlugin, vpn_db.VPNPluginRpcDbMixin):
```
to:
```python
class VPNDriverPlugin(VPNPlugin, vpn_db.VPNPluginRpcDbMixin,
                      vpn_ext_gw_db.VPNExtGWPlugin_db,
                      vpn_agentschedulers_db.VPNAgentSchedulerDbMixin):
```

**Fix C — Patches must be applied to ALL four neutron containers:**

There are four independent neutron containers each running their own Python process:
- `neutron_server_old` — HTTP API (uwsgi)
- `neutron_rpc_server` — RabbitMQ RPC handler (handles all agent RPCs)
- `neutron_periodic_worker` — periodic tasks
- `neutron_ovn_maintenance_worker` — OVN maintenance

Patching only one container leaves the others running old bytecode.

---

### BUG 2 — 400 "Missing peer CIDRs"

**Root cause:** OVN mode does not support `--subnet` on VPN service creation.

**Fix:** Create VPN service without `--subnet`:
```bash
openstack vpn service create VPN-SERVICE --router $ROUTER_ID
```

---

### BUG 3 — Stale bytecode cache

**Root cause:** Python loads cached `.pyc` files instead of patched `.py` files
after container restart.

**Fix:** Always clear pyc cache after every patch before restarting:
```bash
docker exec --user root ${CONTAINER} find \
  /var/lib/kolla/venv/lib/python3.12/site-packages/neutron_vpnaas/ \
  -name "*.pyc" -delete
```

---

### BUG 4 — neutron-ovn-vpn-agent exits silently after "monkey_patched"

**Root cause chain:**
1. Wrong `log_file` path in `neutron.conf`
2. OVS socket not mounted into container
3. Missing `[ovn]` section in `neutron_ovn_vpn_agent.ini`
4. `sync()` triggered RPC call → neutron-server crashed → oslo_service caught exception → silent exit code 0

**Fix — correct `neutron_ovn_vpn_agent.ini`:**
```ini
[DEFAULT]
debug = true
log_file = /var/log/kolla/neutron/neutron-ovn-vpn-agent.log

[vpnagent]
vpn_device_driver = neutron_vpnaas.services.vpn.device_drivers.ovn_ipsec.OvnStrongSwanDriver

[ovn]
ovn_nb_connection = tcp:172.21.208.100:6641
ovn_sb_connection = tcp:172.21.208.100:6642

[ovs]
ovsdb_connection = unix:/var/run/openvswitch/db.sock
```

**Fix — canonical agent start command:**
```bash
docker rm neutron_ovn_vpn_agent 2>/dev/null
docker run -d --name neutron_ovn_vpn_agent \
  --network host --privileged --user root \
  -v /etc/kolla/neutron-ovn-vpn-agent/neutron.conf:/etc/neutron/neutron.conf:ro \
  -v /etc/kolla/neutron-ovn-vpn-agent/neutron_vpnaas.conf:/etc/neutron/neutron_vpnaas.conf:ro \
  -v /etc/kolla/neutron-ovn-vpn-agent/neutron_ovn_vpn_agent.ini:/etc/neutron/neutron_ovn_vpn_agent.ini:ro \
  -v /var/run/openvswitch/db.sock:/var/run/openvswitch/db.sock \
  --entrypoint bash neutron-vpn-agent:local \
  -c "
    mkdir -p /var/log/kolla/neutron /var/run/charon /etc/ipsec.d
    touch /etc/ipsec.secrets && chmod 600 /etc/ipsec.secrets
    /usr/lib/ipsec/charon &
    sleep 5
    python3 /var/lib/kolla/venv/bin/neutron-ovn-vpn-agent \
      --config-file /etc/neutron/neutron.conf \
      --config-file /etc/neutron/neutron_vpnaas.conf \
      --config-file /etc/neutron/neutron_ovn_vpn_agent.ini \
      --debug
  "
```

---

### BUG 5 — `_get_agent_hosting_vpn_services` returns empty

**Root cause:** `IPsecVpnOvnDriverCallBack._get_agent_hosting_vpn_services` called
`get_vpn_agent_on_host()` which queries the legacy agents table. The OVN VPN
agent never registers in that table.

**Fix — patch `ovn_ipsec.py` lines 94–99:**
```python
def _get_agent_hosting_vpn_services(self, context, host):
    # OVN all-in-one: agent does not register in legacy agents table.
    # Return all VPN services that have active connections directly.
    query = context.session.query(vpn_models.VPNService)
    query = query.join(vpn_models.IPsecSiteConnection)
    return query
```

---

### BUG 6 — VyOS remote-address pointing to wrong IP

**Root cause:** The OVN router's main external IP (`192.168.200.180`) is used for
regular SNAT. OVN allocates a separate dedicated port (`192.168.200.199`) for the
VPN service. VyOS was configured to connect to `192.168.200.180` — IKE packets
arrived at the wrong interface and were ignored.

**Fix on VyOS:**
```
configure
set vpn ipsec site-to-site peer OPENSTACK-VPN remote-address 192.168.200.199
set vpn ipsec site-to-site peer OPENSTACK-VPN authentication remote-id 192.168.200.199
commit
save
```

---

### BUG 7 — PSK stored encoded in ipsec.secrets

**Root cause:** The agent wrote an encoded PSK to the secrets file instead of
plaintext. Resolved by confirming the DB contains the plaintext PSK directly.

**Workaround (applied when needed):**
```bash
docker exec --user root neutron_ovn_vpn_agent bash -c "
cat > /var/lib/neutron/kolla/ipsec/ad6b6c07-e390-470b-afbc-e41b159cbfa7/etc/ipsec.secrets << 'EOF'
192.168.200.199 192.168.200.50 : PSK \"L4BVPN-S3CR3T-2025\"
EOF
"
docker exec neutron_ovn_vpn_agent \
  ip netns exec qvpn-ad6b6c07-e390-470b-afbc-e41b159cbfa7 ipsec rereadsecrets
```

---

### BUG 8 — VyOS TS_UNACCEPTABLE / CHILD_SA fails

**Root cause:** Duplicate `remote-address` entries and missing
`tunnel 1 remote prefix` on VyOS — traffic selectors did not match.

**Fix on VyOS:**
```
configure
delete vpn ipsec site-to-site peer OPENSTACK-VPN remote-address 192.168.200.180
set vpn ipsec site-to-site peer OPENSTACK-VPN tunnel 1 remote prefix 10.0.0.0/24
commit
save
```

---

### Final Working VPN Objects

```bash
openstack vpn ike policy create OS-IKE-POLICY \
  --ike-version v2 --auth-algorithm sha256 \
  --encryption-algorithm aes-256 \
  --phase1-negotiation-mode main \
  --pfs group14 --lifetime units=seconds,value=86400

openstack vpn ipsec policy create OS-IPSEC-POLICY \
  --auth-algorithm sha256 --encryption-algorithm aes-256 \
  --encapsulation-mode tunnel --transform-protocol esp \
  --pfs group14 --lifetime units=seconds,value=3600

openstack vpn service create VPN-SERVICE --router $ROUTER_ID

openstack vpn endpoint group create LOCAL-EG \
  --type subnet --value $SUBNET_ID

openstack vpn endpoint group create REMOTE-EG \
  --type cidr --value '172.21.208.0/20'

openstack vpn ipsec site connection create SITE-CONN-VYOS \
  --vpnservice VPN-SERVICE \
  --ikepolicy OS-IKE-POLICY \
  --ipsecpolicy OS-IPSEC-POLICY \
  --local-endpoint-group LOCAL-EG \
  --peer-endpoint-group REMOTE-EG \
  --peer-address 192.168.200.50 \
  --peer-id 192.168.200.50 \
  --psk 'L4BVPN-S3CR3T-2025' \
  --initiator response-only
```

---

## 4. Part 2 — Octavia LBaaS Deployment

### Pre-Deployment Rules (Non-Negotiable)

- **Always use `--tags octavia`** — never run bare `deploy` or `reconfigure` or it will recreate neutron containers and destroy VPN patches.
- **Always verify VPN status** after every Kolla operation.
- **Never use `--tags neutron`** unless VPN patches have been backed up and you are prepared to re-apply them immediately after.

---

### Step 1 — globals.yml Additions

Append to `/etc/kolla/globals.yml`:

```yaml
####################################
# Octavia - Load Balancer (OVN AIO)
####################################
enable_octavia: "yes"
enable_octavia_jobboard: "no"
enable_horizon_octavia: "yes"
# enable_octavia_driver_agent auto-resolves to "yes" via default expression
# because neutron_plugin_agent = "ovn"

octavia_auto_configure: "yes"
octavia_amp_image_tag: "amphora"

octavia_amp_flavor:
  name: "amphora"
  is_public: no
  vcpus: 1
  ram: 1024
  disk: 5

# octavia_network_interface: "o-hm0"
# Intentionally commented — enabled after o-hm0 is created in Step 7
```

---

### Step 2 — Pull Octavia Images

```bash
kolla-ansible pull -i ~/all-in-one --tags octavia
```

Expected: 5 images pulled including `octavia-driver-agent` (required for OVN mode).

---

### Step 3 — Generate Octavia Certificates

```bash
kolla-ansible octavia-certificates -i ~/all-in-one
```

Verify: `ls /etc/kolla/config/octavia/` shows 4 `.pem` files.

---

### Step 4 — Create Octavia Database User

> ⚠️ Kolla does not create the Octavia DB user automatically on existing clusters.
> Manual creation is required before deploy or the bootstrap container fails silently.

**ProxySQL specifics for this environment:**
- Admin username: `kolla-admin` (not `admin`)
- Admin port: `6032` on `172.21.208.100`
- All backend users must use `default_hostgroup = 0`
- `mysql` binary does not exist in Kolla containers — use `mariadb`

```bash
OCTAVIA_DB_PASS=$(grep "^octavia_database_password" /etc/kolla/passwords.yml | awk '{print $2}')
DB_ROOT_PASS=$(grep "^database_password:" /etc/kolla/passwords.yml | awk '{print $2}')
PROXYSQL_ADMIN_PASS=$(grep proxysql_admin_password /etc/kolla/passwords.yml | awk '{print $2}')

# Create database and user in MariaDB
docker exec mariadb mariadb -u root -p"${DB_ROOT_PASS}" \
  -e "CREATE DATABASE IF NOT EXISTS octavia CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
docker exec mariadb mariadb -u root -p"${DB_ROOT_PASS}" \
  -e "GRANT ALL PRIVILEGES ON octavia.* TO 'octavia'@'%' IDENTIFIED BY '${OCTAVIA_DB_PASS}';"
docker exec mariadb mariadb -u root -p"${DB_ROOT_PASS}" \
  -e "GRANT ALL PRIVILEGES ON octavia.* TO 'octavia'@'localhost' IDENTIFIED BY '${OCTAVIA_DB_PASS}';"
docker exec mariadb mariadb -u root -p"${DB_ROOT_PASS}" \
  -e "FLUSH PRIVILEGES; SELECT user, host FROM mysql.user WHERE user='octavia';"

# Register user in ProxySQL with correct hostgroup 0
docker exec mariadb mariadb \
  -u kolla-admin -p"${PROXYSQL_ADMIN_PASS}" \
  -h 172.21.208.100 -P 6032 --skip-ssl \
  -e "INSERT INTO mysql_users (username, password, default_hostgroup)
      VALUES ('octavia', '${OCTAVIA_DB_PASS}', 0)
      ON DUPLICATE KEY UPDATE password='${OCTAVIA_DB_PASS}', default_hostgroup=0;
      LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;"

# Test connection through ProxySQL
docker exec mariadb mariadb \
  -u octavia -p"${OCTAVIA_DB_PASS}" \
  -h 172.21.208.111 -P 3306 --skip-ssl \
  -e "SHOW DATABASES;" 2>&1 | grep -E "octavia|ERROR"
# Must show: octavia
```

---

### Step 5 — Deploy Octavia

```bash
kolla-ansible deploy -i ~/all-in-one --tags octavia
```

Immediately after:
```bash
source /etc/kolla/admin-openrc.sh
openstack vpn ipsec site connection list -c Name -c Status
# Must be ACTIVE — if not, re-apply VPN patches immediately
```

---

### Step 6 — Post-Deploy

```bash
# Must run WITHOUT --tags
kolla-ansible post-deploy -i ~/all-in-one
```

---

### Step 7 — Collect Resource IDs and Update globals.yml

```bash
source /etc/kolla/admin-openrc.sh

MGMT_NET_ID=$(openstack network list | grep lb-mgmt-net | grep -v "^+" | awk '{print $2}' | head -1)
SEC_GRP_ID=$(openstack security group list | grep lb-mgmt-sec-grp | grep -v "| admin" | awk '{print $2}' | head -1)
FLAVOR_ID=$(openstack flavor list --all | grep amphora | awk '{print $2}' | head -1)
AMP_IMAGE_OWNER=$(docker exec octavia_worker grep "amp_image_owner_id" /etc/octavia/octavia.conf | awk '{print $3}')

sudo tee -a /etc/kolla/globals.yml << IDSEOF

# Octavia resource IDs
octavia_amp_boot_network_list: "${MGMT_NET_ID}"
octavia_amp_secgroup_list: "${SEC_GRP_ID}"
octavia_amp_flavor_id: "${FLAVOR_ID}"
octavia_amp_image_owner_id: "${AMP_IMAGE_OWNER}"
IDSEOF
```

---

### Step 8 — Create o-hm0 Health Manager Interface

> This is the most critical step. Without o-hm0:
> - `octavia_health_manager` stays unhealthy
> - `controller_ip_port_list` points to wrong IP
> - All load balancers stay in `PENDING_CREATE` forever

```bash
source /etc/kolla/admin-openrc.sh

# Create Neutron port
openstack port create \
  --network $MGMT_NET_ID \
  --device-owner Octavia:health-mgr \
  --host=$(hostname) \
  octavia-health-manager-listen-port

# Capture port details
PORT_ID=$(openstack port show octavia-health-manager-listen-port -f value -c id)
PORT_MAC=$(openstack port show octavia-health-manager-listen-port -f value -c mac_address)
PORT_IP=$(openstack port show octavia-health-manager-listen-port \
  -f json -c fixed_ips | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['fixed_ips'][0]['ip_address'])")

# Create OVS port
sudo ovs-vsctl add-port br-int o-hm0 \
  -- set Interface o-hm0 type=internal \
  -- set Interface o-hm0 external-ids:iface-status=active \
  -- set Interface o-hm0 external-ids:attached-mac=${PORT_MAC} \
  -- set Interface o-hm0 external-ids:iface-id=${PORT_ID} \
  -- set Interface o-hm0 external-ids:skip_cleanup=true

sudo ip link set o-hm0 address ${PORT_MAC}
sudo ip link set o-hm0 up
sudo ip addr add ${PORT_IP}/24 dev o-hm0
```

**Systemd persistence service:**

> ⚠️ Use `docker.service` as dependency — NOT `openvswitch-switch.service`.
> In Kolla Docker deployments, OVS runs inside a container. The systemd unit
> for openvswitch does not exist in this environment.

```bash
sudo tee /etc/systemd/system/octavia-o-hm0.service << SVCEOF
[Unit]
Description=Octavia o-hm0 health manager interface
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  ovs-vsctl --may-exist add-port br-int o-hm0 \
    -- set Interface o-hm0 type=internal \
    -- set Interface o-hm0 external-ids:iface-status=active \
    -- set Interface o-hm0 external-ids:attached-mac=${PORT_MAC} \
    -- set Interface o-hm0 external-ids:iface-id=${PORT_ID} \
    -- set Interface o-hm0 external-ids:skip_cleanup=true; \
  ip link set o-hm0 address ${PORT_MAC}; \
  ip link set o-hm0 up; \
  ip addr add ${PORT_IP}/24 dev o-hm0 2>/dev/null || true'
ExecStop=/sbin/ip link set o-hm0 down

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable octavia-o-hm0.service
sudo systemctl start octavia-o-hm0.service
```

**Enable octavia_network_interface and reconfigure:**

```bash
sudo sed -i 's|#octavia_network_interface: "o-hm0"|octavia_network_interface: "o-hm0"|' \
  /etc/kolla/globals.yml

kolla-ansible reconfigure -i ~/all-in-one --tags octavia

# Verify
grep "controller_ip_port_list" /etc/kolla/octavia-health-manager/octavia.conf
# Must show: 10.1.0.x:5555 — NOT 172.21.208.x:5555
```

---

### Step 9 — Upload Amphora Image

```bash
source /etc/kolla/admin-openrc.sh
AMP_IMAGE_OWNER=$(docker exec octavia_worker grep "amp_image_owner_id" /etc/octavia/octavia.conf | awk '{print $3}')

wget https://tarballs.opendev.org/openstack/octavia/test-images/test-only-amphora-x64-haproxy-ubuntu-jammy.qcow2 \
  -O ~/amphora.qcow2

openstack image create "amphora-v2" \
  --file ~/amphora.qcow2 \
  --disk-format qcow2 \
  --container-format bare \
  --tag amphora \
  --private \
  --project $AMP_IMAGE_OWNER
```

> ⚠️ The `--project` flag is mandatory. If the image is uploaded under the wrong
> project, amphora VMs will boot but show `OFFLINE` permanently.

Verify owner matches worker config:
```bash
openstack image show amphora-v2 -c owner -c tags -c status
docker exec octavia_worker grep "amp_image_owner_id" /etc/octavia/octavia.conf
# These two owner values must be identical
```

---

### Step 10 — Enable DHCP on lb-mgmt-subnet

```bash
SUBNET_ID=$(openstack subnet list | grep lb-mgmt-subnet | awk '{print $2}')
openstack subnet set --dhcp $SUBNET_ID
openstack subnet show $SUBNET_ID | grep enable_dhcp
# Must show: True
```

---

### Step 11 — Horizon Reconfigure

```bash
sudo mkdir -p /etc/kolla/config/horizon
sudo tee /etc/kolla/config/horizon/_9999-custom-settings.py << 'EOF'
OPENSTACK_HOST = "172.21.208.111"
OPENSTACK_KEYSTONE_URL = "http://172.21.208.111:5000/v3"
OPENSTACK_ENDPOINT_TYPE = "publicURL"
EOF

kolla-ansible reconfigure -i ~/all-in-one --tags horizon
```

---

## 5. Part 3 — Horizon Bugs and Fixes

### BUG H1 — 503 Bad Gateway after Horizon reconfigure

**Symptom:** `http://172.21.208.111/` returns HTTP 503.

**Root cause:** After `kolla-ansible reconfigure --tags horizon`, the Horizon
container restarts and the `django-admin compress` startup step may fail if the
container is not fully initialized, leaving static assets uncompressed. HAProxy
keeps routing to Horizon, but Horizon returns 503 because uWSGI workers are
crashing.

**Fix:**
```bash
docker restart horizon
sleep 15
curl -s -o /dev/null -w "%{http_code}" http://172.21.208.111/
# Should return 200 or 302
```

If 503 persists, check logs:
```bash
docker logs horizon --tail 50
```

---

### BUG H2 — "Something went wrong! An unexpected error has occurred" on all pages

**Symptom:** After restarting Horizon to fix the 503, every page shows the
generic Django error page: *"Something went wrong! An unexpected error has
occurred."*

**Root cause:** During `kolla-ansible reconfigure`, the `django-admin compress`
command ran as **root** inside the Horizon container. This left the compressed
static CSS/JS files owned by `root` inside the container at:

```
/var/lib/kolla/venv/.../static/dashboard/css/output.*.css  ← owned by root
```

When Horizon's web process (which runs as the unprivileged `horizon` user) tried
to serve or regenerate those files, it received **errno 13 Permission Denied**.
Django's compressor could not compress/render templates, so every page request
crashed and showed the generic error.

**Diagnostic — confirm this is the issue:**
```bash
# Check for root-owned files in static directory
docker exec -u root horizon find /var/lib/kolla/venv/lib/python3.12/site-packages/static/ \
  -not -user horizon 2>/dev/null | head -20
# If this lists files → confirmed root-ownership bug

# Check Django logs for errno 13
docker logs horizon 2>&1 | grep -i "permission\|errno 13\|compress" | tail -20
```

**Fix — step by step:**

```bash
# Step 1: Fix ownership of all static files
docker exec -u root horizon chown -R horizon:horizon \
  /var/lib/kolla/venv/lib/python3.12/site-packages/static/

# Step 2: Verify no root-owned files remain
docker exec -u root horizon find \
  /var/lib/kolla/venv/lib/python3.12/site-packages/static/ \
  -not -user horizon 2>/dev/null | wc -l
# Must return 0

# Step 3: Re-run django compress as horizon user
docker exec -u horizon horizon bash -c "
  source /var/lib/kolla/venv/bin/activate
  django-admin compress --force \
    --settings=openstack_dashboard.settings \
    --pythonpath=/var/lib/kolla/venv/lib/python3.12/site-packages
"

# Step 4: Restart the container
docker restart horizon

# Step 5: Verify recovery
sleep 15
curl -s -o /dev/null -w "%{http_code}" http://172.21.208.111/
# Must return 200 or 302
```

**If the static path differs** (verify first):
```bash
docker exec -u horizon horizon bash -c "
  source /var/lib/kolla/venv/bin/activate
  python3 -c \"import openstack_dashboard.settings as s; print(getattr(s,'COMPRESS_ROOT','NOT SET'))\"
"
# Use the path printed here in the chown command above
```

**Prevention:** This bug is triggered by `kolla-ansible reconfigure --tags horizon`.
After every Horizon reconfigure, always run:
```bash
docker exec -u root horizon chown -R horizon:horizon \
  /var/lib/kolla/venv/lib/python3.12/site-packages/static/
docker restart horizon
```

---

## 6. Part 4 — Post-Deployment Bugs and Fixes

These bugs were encountered after the initial deployment was complete, during
integration and verification of Horizon and Octavia.

---

### BUG P1 — Horizon "Something went wrong" after login (static file permissions)

**Symptom:** Login page loads fine, but after submitting credentials the generic
Django error page appears on every page.

**Root cause:** `kolla-ansible reconfigure --tags horizon` ran `django-admin compress`
as `root` inside the container. This left compressed CSS/JS files owned by `root`.
The Horizon uWSGI process runs as the unprivileged `horizon` user and gets
`errno 13 Permission Denied` on every template render.

**Diagnosis:**
```bash
docker exec -u root horizon find \
  /var/lib/kolla/venv/lib/python3.12/site-packages/static/ \
  -not -user horizon 2>/dev/null | head -10
# If this lists files → confirmed root-ownership bug
```

**Fix:**
```bash
docker exec -u root horizon chown -R horizon:horizon \
  /var/lib/kolla/venv/lib/python3.12/site-packages/static/

docker exec -u horizon horizon bash -c "
  source /var/lib/kolla/venv/bin/activate
  django-admin compress --force \
    --settings=openstack_dashboard.settings \
    --pythonpath=/var/lib/kolla/venv/lib/python3.12/site-packages
"
docker restart horizon
sleep 20
curl -s -o /dev/null -w "%{http_code}" http://172.21.208.111/
# Must return 302
```

**Prevention:** Run after every `kolla-ansible reconfigure --tags horizon`:
```bash
docker exec -u root horizon chown -R horizon:horizon \
  /var/lib/kolla/venv/lib/python3.12/site-packages/static/
docker restart horizon
```

---

### BUG P2 — Horizon login loop / session error (broken Keystone endpoint)

**Symptom:** uWSGI log shows:
```
RuntimeError: Unable to create a new session key. It is likely that the cache is unavailable.
```
And endpoint list shows `http://http://172.21.208.111/:5000/v3` — double `http://` prefix.

**Root cause:** `kolla-ansible reconfigure --tags horizon` re-registered the Keystone
endpoint using a value that already contained `http://`, prepending another one.
Horizon reads the identity endpoint from the catalog after login, hits the broken URL,
fails to create a session, and shows the generic error.

**Fix:**
```bash
source /etc/kolla/admin-openrc.sh

# Fix broken endpoints
for IFACE in public internal; do
  ID=$(openstack endpoint list --service identity --interface $IFACE -f value -c ID)
  openstack endpoint set --url "http://172.21.208.111:5000/v3" $ID
done

# Create admin endpoint if missing
openstack endpoint create --region RegionOne \
  identity admin "http://172.21.208.111:5000/v3"

# Flush caches
docker exec keystone keystone-manage token_flush 2>/dev/null || true
docker restart memcached
```

**Verify — all three must show the correct URL:**
```bash
openstack endpoint list --service identity -f value -c "Interface" -c "URL"
# public   http://172.21.208.111:5000/v3
# internal http://172.21.208.111:5000/v3
# admin    http://172.21.208.111:5000/v3
```

---

### BUG P3 — Octavia API unreachable through VIP (HAProxy missing frontend)

**Symptom:** `openstack loadbalancer list` fails with `Connection refused` on port 9876.
Direct to `172.21.208.100:9876` works but `172.21.208.111:9876` (VIP) does not.
`docker exec haproxy cat /etc/haproxy/haproxy.cfg | grep 9876` returns empty.

**Root cause:** HAProxy was never reconfigured after Octavia was deployed, so it
never added the Octavia frontend. Octavia API was bound to host IP only.

**Fix:**
```bash
# Backup VPN patches first (mandatory)
sudo docker cp neutron_rpc_server:/var/lib/kolla/venv/lib/python3.12/site-packages/neutron_vpnaas/services/vpn/service_drivers/ovn_ipsec.py \
  /root/vpnaas-patch-backup/ovn_ipsec_patched.py

kolla-ansible reconfigure -i ~/all-in-one --tags haproxy

# Verify VPN survived
openstack vpn ipsec site connection list -c Name -c Status

# Verify Octavia reachable through VIP
curl -s http://172.21.208.111:9876/ | python3 -m json.tool | head -5

# Fix endpoint if pointing to host IP
for IFACE in public internal; do
  ID=$(openstack endpoint list --service load-balancer --interface $IFACE -f value -c ID)
  URL=$(openstack endpoint list --service load-balancer --interface $IFACE -f value -c URL)
  if echo "$URL" | grep -q "172.21.208.100"; then
    openstack endpoint set --url "http://172.21.208.111:9876" $ID
    echo "Fixed $IFACE: $URL → http://172.21.208.111:9876"
  fi
done
```

---

### BUG P4 — Amphora stuck ALLOCATED / LB stuck OFFLINE after worker timeout

**Symptom:** Load balancer `provisioning_status=ACTIVE` but `operating_status=OFFLINE`.
Amphora VM is running and pingable. tcpdump shows heartbeats arriving at `o-hm0:5555`
but LB never goes ONLINE. Amphora status in DB is `ALLOCATED` instead of `READY`.

**Root cause chain:**
1. Nova boot took ~60 seconds. Worker's `amp_active_retries` ran out before the
   amphora agent started → worker flow REVERTED, amphora left in `ALLOCATED` state.
2. The health manager had crashed earlier due to a transient DB `Errno 113` error
   (before HAProxy was reconfigured to forward port 3306 on the VIP).
3. Health manager ignores heartbeats from `ALLOCATED` amphorae — only processes `READY`.
4. Result: heartbeats arrive every 10 seconds but nobody processes them.

**Diagnosis:**
```bash
# Confirm heartbeats are arriving
sudo tcpdump -i any -n "port 5555" -c 5 2>/dev/null
# Must show: 10.1.0.75 → 10.1.0.146:5555 UDP packets

# Check amphora state in DB
OCTAVIA_DB_PASS=$(grep "^octavia_database_password" /etc/kolla/passwords.yml | awk '{print $2}')
docker exec mariadb mariadb -u octavia -p"${OCTAVIA_DB_PASS}" \
  -h 172.21.208.111 -P 3306 --skip-ssl octavia \
  -e "SELECT id, status FROM amphora;
      SELECT id, provisioning_status, operating_status FROM load_balancer;"
# amphora status = ALLOCATED ← this is the problem
```

**Fix:**
```bash
OCTAVIA_DB_PASS=$(grep "^octavia_database_password" /etc/kolla/passwords.yml | awk '{print $2}')
AMP_ID=$(docker exec mariadb mariadb -u octavia -p"${OCTAVIA_DB_PASS}" \
  -h 172.21.208.111 -P 3306 --skip-ssl octavia \
  -sNe "SELECT id FROM amphora WHERE status='ALLOCATED' LIMIT 1;")

docker exec mariadb mariadb -u octavia -p"${OCTAVIA_DB_PASS}" \
  -h 172.21.208.111 -P 3306 --skip-ssl octavia \
  -e "UPDATE amphora SET status='READY' WHERE id='${AMP_ID}';
      UPDATE load_balancer SET operating_status='ONLINE'
      WHERE id=(SELECT load_balancer_id FROM amphora WHERE id='${AMP_ID}');"

docker restart octavia_health_manager
sleep 30
openstack loadbalancer list -c name -c provisioning_status -c operating_status
# Must show ACTIVE / ONLINE
```

**Prevention:** After any HAProxy reconfigure, always restart health manager:
```bash
docker restart octavia_health_manager
```

---

## 7. Part 5 — Known Issues and Fixes

### ProxySQL: heredoc does not expand variables inside docker exec

Shell heredocs passed to `docker exec` do not expand host-side variables. Always
use `-e "..."` with explicit variable interpolation:

```bash
# WRONG — variable not expanded inside container
docker exec mariadb mariadb -u root -p"${PASS}" << EOF
GRANT ... IDENTIFIED BY '${OCTAVIA_DB_PASS}';
EOF

# CORRECT
docker exec mariadb mariadb -u root -p"${PASS}" \
  -e "GRANT ... IDENTIFIED BY '${OCTAVIA_DB_PASS}';"
```

### ProxySQL: admin username is `kolla-admin`, not `admin`

Kolla's ProxySQL uses `kolla-admin` as the admin username. The admin interface
listens on port `6032` on `172.21.208.100` and `172.21.208.111`.

### ProxySQL: new users must use `default_hostgroup = 0`

All Kolla OpenStack service users use hostgroup `0`. Always set
`default_hostgroup=0` when inserting new users into ProxySQL's `mysql_users`.

### Octavia deploy: `failed=0` but bootstrap fails silently

If the DB user is not in ProxySQL before deploy, the bootstrap container fails
to connect and the DB schema is never created. The deploy may still report
success. Always pre-create the DB user and verify via ProxySQL before deploying.

### o-hm0 systemd dependency

`openvswitch-switch.service` does not exist in Kolla Docker deployments. Use
`docker.service` as the After/Requires dependency in the systemd unit.

### Octavia post-deploy has no tags

In Kolla 2025.2, `kolla-ansible post-deploy --tags octavia` only runs 2 tasks.
Always run post-deploy **without** `--tags`.

---

## 8. Part 6 — Operational Reference

### Verify Everything is Healthy

```bash
source /etc/kolla/admin-openrc.sh

# VPN tunnel
openstack vpn ipsec site connection list -c Name -c Status
# Must show ACTIVE

# Octavia containers
docker ps --format "{{.Names}}\t{{.Status}}" | grep octavia

# Health manager binding
sudo ss -tulnp | grep 5555
# Must show 10.1.0.x:5555 — NOT 172.21.208.x:5555

# o-hm0 interface
ip addr show o-hm0

# Horizon HTTP status
curl -s -o /dev/null -w "Horizon HTTP: %{http_code}\n" http://172.21.208.111/
# Must return 200 or 302
```

### Test Load Balancer Creation

```bash
SUBNET_ID=$(openstack subnet show demo-subnet -f value -c id)
openstack loadbalancer create --name test-lb --vip-subnet-id $SUBNET_ID
watch -n 5 'openstack loadbalancer show test-lb -c provisioning_status -c operating_status'
# PENDING_CREATE → ACTIVE in 2-4 minutes
```

### Re-apply VPN Patches After Reboot

```bash
for CONTAINER in neutron_server_old neutron_rpc_server neutron_periodic_worker neutron_ovn_maintenance_worker; do
  sudo docker cp /root/vpnaas-patch-backup/ovn_ipsec_patched.py \
    ${CONTAINER}:/var/lib/kolla/venv/lib/python3.12/site-packages/neutron_vpnaas/services/vpn/service_drivers/ovn_ipsec.py
  sudo docker cp /root/vpnaas-patch-backup/plugin_patched.py \
    ${CONTAINER}:/var/lib/kolla/venv/lib/python3.12/site-packages/neutron_vpnaas/services/vpn/plugin.py
  docker exec --user root ${CONTAINER} find \
    /var/lib/kolla/venv/lib/python3.12/site-packages/neutron_vpnaas/ \
    -name "*.pyc" -delete
  docker restart ${CONTAINER}
done
```

### Fix Horizon After Any Reconfigure

```bash
# Run this after every kolla-ansible reconfigure --tags horizon
docker exec -u root horizon chown -R horizon:horizon \
  /var/lib/kolla/venv/lib/python3.12/site-packages/static/
docker restart horizon
sleep 15
curl -s -o /dev/null -w "Horizon HTTP: %{http_code}\n" http://172.21.208.111/
```

---

## 9. What NOT To Do

| Action | Risk |
|--------|------|
| `kolla-ansible deploy` without `--tags` | Recreates neutron containers, destroys VPN patches |
| `kolla-ansible reconfigure` without `--tags` | Same as above |
| `docker exec ... mariadb << EOF` heredoc with variables | Variables not expanded — creates broken DB users |
| Using `default_hostgroup=1` for new ProxySQL users | Hostgroup 1 has no backend — connection timeout |
| Using `admin` as ProxySQL admin username | Wrong — Kolla uses `kolla-admin` |
| Uploading amphora image without `--project` | Owner mismatch — amphora stays OFFLINE |
| Using `openvswitch-switch.service` in systemd | Service fails on boot — OVS runs in Docker |
| `kolla-ansible post-deploy --tags octavia` | Skips Octavia-specific post-deploy tasks |
| `kolla-ansible reconfigure --tags horizon` without fixing perms | Horizon "Something went wrong" on every page |
| Running `kolla-ansible reconfigure` without `--tags haproxy` after Octavia deploy | Octavia API unreachable through VIP |
| Not restarting `octavia_health_manager` after HAProxy reconfigure | Amphora stuck ALLOCATED, LB stays OFFLINE |
| Leaving amphora in ALLOCATED state | Health manager ignores heartbeats, LB stays OFFLINE forever |
| Restarting `neutron_l3_agent` | Drops VPN tunnels |
| `kolla-ansible reconfigure --tags horizon` without fixing perms | Horizon "Something went wrong" on every page |

---

*Deployment completed and verified: May 2026*
*OpenStack 2025.2 | Kolla-Ansible | Ubuntu 24.04 | OVN | Hyper-V*
*All steps verified working in production-like single-node environment.*
