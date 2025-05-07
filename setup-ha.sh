#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# HA Setup Script for cloud-proxy Hosts
# Installs configs and README for:
#  - Docker Compose (MariaDB Galera + Nginx Proxy Manager)
#  - Keepalived (Floating IP failover)
#  - Syncthing (Bidirectional sync of /opt/npm-data and Let’s Encrypt certs)
# Usage: export VAR=... && ./setup-ha.sh  (all variables must be set)
# =============================================================

# 1) Prompt for required variables if unset
vars=(HOST_IP PEER_IPS FLOATING_IP ROLE PRIORITY SYNCTHING_DEVICE_ID SYNCTHING_PEER_DEVICE_IDS
  DB_ROOT_PASS DB_USER DB_USER_PASS DB_NAME CLUSTER_NAME XTRABACKUP_PASSWORD LETSENCRYPT_DIR PUID PGID)
prompts=(
  "this host’s IP (e.g. 10.0.0.2)"
  "comma-separated peer IPs (e.g. 10.0.0.2,10.0.0.3)"
  "floating IP (e.g. 10.0.0.100)"
  "Keepalived role: MASTER or BACKUP"
  "VRRP priority (use 150 for MASTER, 100 for BACKUP)"
  "this host’s Syncthing Device ID"
  "peer Syncthing Device IDs, comma-separated"
  "MariaDB root password (no defaults)"
  "MariaDB user name (no defaults)"
  "MariaDB user password (no defaults)"
  "MariaDB database name (no defaults)"
  "Galera cluster name (no defaults)"
  "XtraBackup password for SST (no defaults)"
  "host path to Let’s Encrypt data (e.g. /etc/letsencrypt)"
  "user ID for NPM container (PUID, e.g. 1000)"
  "group ID for NPM container (PGID, e.g. 1000)"
)
for i in "${!vars[@]}"; do
  var_name=${vars[i]}
  prompt=${prompts[i]}
  if [ -z "${!var_name:-}" ]; then
    read -rp "Enter ${var_name} (${prompt}): " value
    export ${var_name}="$value"
  fi
done

# 2) Define constant paths
DATA_DIR="/opt/npm-data"
MYSQL_CONF_DIR="/etc/mysql/conf.d"
KEEPALIVED_CONF_DIR="/etc/keepalived"
SYNCTHING_CONF_DIR="/root/.config/syncthing"

# 3) Install system dependencies (skip Docker)
echo "==> Installing system dependencies..."
apt update && apt install -y \
  keepalived syncthing curl jq apt-transport-https ca-certificates gnupg

# 4) Install Hetzner Cloud CLI from GitHub Releases
echo "==> Installing hcloud CLI..."
HCL_REL=$(curl -s https://api.github.com/repos/hetznercloud/cli/releases/latest | jq -r .tag_name)
ARCH="linux-amd64"
URL="https://github.com/hetznercloud/cli/releases/download/${HCL_REL}/hcloud-${ARCH}.tar.gz"
curl -L "$URL" -o hcloud.tar.gz
tar xzf hcloud.tar.gz
mv hcloud /usr/local/bin/hcloud
chmod +x /usr/local/bin/hcloud
rm hcloud.tar.gz LICENSE
hcloud version

# 5) Enable services
echo "==> Enabling keepalived and syncthing services..."
systemctl enable keepalived
systemctl enable syncthing@root

# 6) Prepare directories and DB init script
echo "==> Preparing directories and database init..."
mkdir -p "$DATA_DIR" "$MYSQL_CONF_DIR" "$KEEPALIVED_CONF_DIR" "$SYNCTHING_CONF_DIR" db-init
cat >db-init/init.sql <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_USER_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
EOF

# 7) Generate docker-compose.yml (with local MariaDB port)
echo "==> Generating docker-compose.yml..."
cat >docker-compose.yml <<EOF
version: '3.8'

services:
  mariadb:
    image: mariadb:10.5
    container_name: npm-db
    ports:
      - "127.0.0.1:3306:3306"
    environment:
      MYSQL_ROOT_PASSWORD: "${DB_ROOT_PASS}"
      CLUSTER_NAME: "${CLUSTER_NAME}"
      XTRABACKUP_PASSWORD: "${XTRABACKUP_PASSWORD}"
    volumes:
      - galera-data:/var/lib/mysql
      - ./db-init:/docker-entrypoint-initdb.d
    networks:
      - galera-net

  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm-app
    depends_on:
      - mariadb
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - DB_MYSQL_HOST=mariadb
      - DB_MYSQL_USER=${DB_USER}
      - DB_MYSQL_PASSWORD=${DB_USER_PASS}
      - DB_MYSQL_NAME=${DB_NAME}
    volumes:
      - "${DATA_DIR}:/data"
      - "${LETSENCRYPT_DIR}:/etc/letsencrypt"
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    networks:
      - galera-net

networks:
  galera-net:
    driver: bridge

volumes:
  galera-data:
EOF

# 8) Deploy stack
echo "==> Starting Docker Compose stack..."
docker compose up -d

# 9) Generate Galera config
echo "==> Generating Galera config..."
cat >"${MYSQL_CONF_DIR}/galera.cnf" <<EOF
[mysqld]
wsrep_on=ON
wsrep_provider=/usr/lib/galera/libgalera_smm.so
wsrep_cluster_address="gcomm://${HOST_IP},${PEER_IPS}"
wsrep_cluster_name="${CLUSTER_NAME}"
wsrep_node_address="${HOST_IP}"
wsrep_node_name="cloud-proxy-$(hostname)"
wsrep_sst_method=xtrabackup-v2
EOF

# 10) Generate Keepalived config
echo "==> Generating Keepalived config..."
cat >"${KEEPALIVED_CONF_DIR}/keepalived.conf" <<EOF
vrrp_instance VI_1 {
  interface eth0
  state ${ROLE}
  virtual_router_id 51
  priority ${PRIORITY}
  advert_int 1
  authentication {
    auth_type PASS
    auth_pass securepass
  }
  virtual_ipaddress {
    ${FLOATING_IP}
  }
}
EOF

# 11) Generate Syncthing config
echo "==> Generating Syncthing config..."
cat >"${SYNCTHING_CONF_DIR}/config.xml" <<EOF
<configuration version="32">
  <device id="${SYNCTHING_DEVICE_ID}" name="$(hostname)" compression="metadata" introducer="false" />
EOF
IFS=',' read -ra PIDS <<<"${SYNCTHING_PEER_DEVICE_IDS}"
# npm-data folder
cat >>"${SYNCTHING_CONF_DIR}/config.xml" <<EOF
  <folder id="npm-data" label="npm-data" path="${DATA_DIR}" type="sendreceive">
EOF
for pid in "${PIDS[@]}"; do
  cat >>"${SYNCTHING_CONF_DIR}/config.xml" <<EOF
    <device id="${pid}" />
EOF
done
cat >>"${SYNCTHING_CONF_DIR}/config.xml" <<EOF
    <ignoreDelete>false</ignoreDelete>
    <rescanIntervalS>60</rescanIntervalS>
  </folder>
EOF
# letsencrypt folder
cat >>"${SYNCTHING_CONF_DIR}/config.xml" <<EOF
  <folder id="letsencrypt" label="letsencrypt" path="${LETSENCRYPT_DIR}" type="sendreceive">
EOF
for pid in "${PIDS[@]}"; do
  cat >>"${SYNCTHING_CONF_DIR}/config.xml" <<EOF
    <device id="${pid}" />
EOF
done
cat >>"${SYNCTHING_CONF_DIR}/config.xml" <<EOF
    <ignoreDelete>false</ignoreDelete>
    <rescanIntervalS>60</rescanIntervalS>
  </folder>
</configuration>
EOF

# 12) Generate README.md
echo "==> Generating README.md..."
cat >README.md <<EOF
# Cloud-Proxy HA Setup

This directory contains everything needed to stand up a two-node, high-availability
Nginx Proxy Manager cluster. Configs are generated by **setup-ha.sh**:

- **MariaDB Galera Cluster**  
- **Keepalived** für floating-IP failover  
- **Syncthing** für bidirectional sync of \`/opt/npm-data\` and Let’s Encrypt certs  

Source repo: https://github.com/jsbrain/cloud-proxy.git

---

## Prerequisites

- Ubuntu 20.04+ (root oder sudo)  
- Network connectivity between both hosts  
- Docker & Docker Compose bereits installiert  
- Hetzner Cloud CLI authenticated (via "hcloud auth login")  

---

## Quickstart

1. Clone on both hosts:  
   \`\`\`bash
   git clone https://github.com/jsbrain/cloud-proxy.git
   cd cloud-proxy
   \`\`\`  
2. Make script executable and run it:  
   \`\`\`bash
   chmod +x setup-ha.sh
   ./setup-ha.sh
   \`\`\`

---

## Beispiel: Alle Variablen per Umgebungsvariable setzen

Vor dem Ausführen müssen alle Variablen exportiert werden, um Eingabeaufforderungen zu vermeiden:

\`\`\`bash
export HOST_IP='10.0.0.2'
export PEER_IPS='10.0.0.2,10.0.0.3'
export FLOATING_IP='10.0.0.100'
export ROLE='MASTER'
export PRIORITY='150'
export SYNCTHING_DEVICE_ID='ABCDEF1234567890'
export SYNCTHING_PEER_DEVICE_IDS='ID1,ID2'
export DB_ROOT_PASS='secureRootPass'
export DB_USER='npmuser'
export DB_USER_PASS='secureUserPass'
export DB_NAME='npmdb'
export CLUSTER_NAME='npm-galera'
export XTRABACKUP_PASSWORD='secureXbckPass'
export LETSENCRYPT_DIR='/etc/letsencrypt'
export PUID='1000'
export PGID='1000'
./setup-ha.sh
\`\`\`

---

## Environment Variables

| Variable                      | Beschreibung                                   |
| ----------------------------- | ---------------------------------------------- |
| \`HOST_IP\`                     | this host’s IP                                 |
| \`PEER_IPS\`                    | comma-separated peer IPs                       |
| \`FLOATING_IP\`                 | VRRP floating IP                               |
| \`ROLE\`                        | Keepalived role (\`MASTER\` oder \`BACKUP\`)    |
| \`PRIORITY\`                    | VRRP priority (höher gewinnt)                  |
| \`SYNCTHING_DEVICE_ID\`         | this host’s Syncthing Device ID                |
| \`SYNCTHING_PEER_DEVICE_IDS\`   | comma-separated peer Syncthing IDs             |
| \`DB_ROOT_PASS\`                | MariaDB root password (erforderlich)           |
| \`DB_USER\`                     | MariaDB user name (erforderlich)               |
| \`DB_USER_PASS\`                | MariaDB user password (erforderlich)           |
| \`DB_NAME\`                     | MariaDB database name (erforderlich)           |
| \`CLUSTER_NAME\`                | Galera cluster name (erforderlich)             |
| \`XTRABACKUP_PASSWORD\`         | XtraBackup password for SST (erforderlich)     |
| \`LETSENCRYPT_DIR\`             | host path to Let’s Encrypt data (erforderlich) |
| \`PUID\`                        | user ID for NPM container (PUID, e.g. 1000)    |
| \`PGID\`                        | group ID for NPM container (PGID, e.g. 1000)    |

EOF

echo "==> All done! See README.md for full details."
