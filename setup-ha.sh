#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# HA Setup Script for cloud-proxy Hosts
# Installs configs and README for:
#  - Docker Compose (using .env for variables)
#    - MariaDB Galera
#    - Nginx Proxy Manager
#  - Keepalived (Floating IP failover)
#  - Syncthing (Bidirectional sync of /opt/npm-data and Let’s Encrypt certs)
# Usage: export VAR=... && ./setup-ha.sh
#        or provide a .env file in repo root
# =============================================================

# 1) Prompt for required variables if unset
vars=(HOST_IP PEER_IPS FLOATING_IP ROLE PRIORITY SYNCTHING_DEVICE_ID SYNCTHING_PEER_DEVICE_IDS
  DB_ROOT_PASS DB_PORT DB_USER DB_USER_PASS DB_NAME CLUSTER_NAME XTRABACKUP_PASSWORD
  LETSENCRYPT_DIR PUID PGID)
prompts=(
  "this host’s IP (e.g. 10.0.0.2)",
  "comma-separated peer IPs (e.g. 10.0.0.2,10.0.0.3)",
  "floating IP (e.g. 10.0.0.100)",
  "Keepalived role: MASTER or BACKUP",
  "VRRP priority (150=MASTER,100=BACKUP)",
  "this host’s Syncthing Device ID",
  "peer Syncthing Device IDs, comma-separated",
  "MariaDB root password (required)",
  "MariaDB port to listen locally (e.g. 3306)",
  "MariaDB user name (required)",
  "MariaDB user password (required)",
  "MariaDB database name (required)",
  "Galera cluster name (required)",
  "XtraBackup password for SST (required)",
  "host path to Let’s Encrypt data (e.g. /etc/letsencrypt)",
  "user ID for NPM container (e.g. 1000)",
  "group ID for NPM container (e.g. 1000)"
)
for i in "${!vars[@]}"; do
  var=${vars[i]}
  prompt=${prompts[i]}
  if [ -z "${!var:-}" ]; then
    read -rp "Enter ${var} (${prompt}): " val
    export ${var}="$val"
  fi
done

# 2) Define constant paths
DATA_DIR="/opt/npm-data"
MYSQL_CONF_DIR="/etc/mysql/conf.d"
KEEPALIVED_CONF_DIR="/etc/keepalived"
SYNCTHING_CONF_DIR="/root/.config/syncthing"

# 3) Install system dependencies
echo "==> Installing system dependencies..."
apt update && apt install -y \
  keepalived syncthing curl jq apt-transport-https ca-certificates gnupg

# 4) Install Hetzner Cloud CLI
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
cat >db-init/init.sql <<'INITSQL'
CREATE DATABASE IF NOT EXISTS `${DB_NAME}`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_USER_PASS}';
GRANT ALL PRIVILEGES ON `${DB_NAME}`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
INITSQL

# 7) Generate .env file for Docker Compose
echo "==> Generating .env file..."
cat >.env <<EOF
HOST_IP=${HOST_IP}
PEER_IPS=${PEER_IPS}
FLOATING_IP=${FLOATING_IP}
ROLE=${ROLE}
PRIORITY=${PRIORITY}
SYNCTHING_DEVICE_ID=${SYNCTHING_DEVICE_ID}
SYNCTHING_PEER_DEVICE_IDS=${SYNCTHING_PEER_DEVICE_IDS}
DB_ROOT_PASS=${DB_ROOT_PASS}
DB_PORT=${DB_PORT}
DB_USER=${DB_USER}
DB_USER_PASS=${DB_USER_PASS}
DB_NAME=${DB_NAME}
CLUSTER_NAME=${CLUSTER_NAME}
XTRABACKUP_PASSWORD=${XTRABACKUP_PASSWORD}
LETSENCRYPT_DIR=${LETSENCRYPT_DIR}
PUID=${PUID}
PGID=${PGID}
EOF

# 8) Generate docker-compose.yml using .env
echo "==> Generating docker-compose.yml..."
cat >docker-compose.yml <<'DOCKERCOMPOSE'
version: '3.8'
services:
  mariadb:
    env_file: .env
    image: mariadb:10.5
    container_name: npm-db
    environment:
      MYSQL_ROOT_PASSWORD: "${DB_ROOT_PASS}"
      CLUSTER_NAME: "${CLUSTER_NAME}"
      XTRABACKUP_PASSWORD: "${XTRABACKUP_PASSWORD}"
    ports:
      - "127.0.0.1:${DB_PORT}:3306"
    volumes:
      - galera-data:/var/lib/mysql
      - ./db-init:/docker-entrypoint-initdb.d
    networks:
      - galera-net

  nginx-proxy-manager:
    env_file: .env
    image: jc21/nginx-proxy-manager:latest
    container_name: npm-app
    depends_on:
      - mariadb
    environment:
      PUID: "${PUID}"
      PGID: "${PGID}"
      DB_MYSQL_HOST: "mariadb"
      DB_MYSQL_USER: "${DB_USER}"
      DB_MYSQL_PASSWORD: "${DB_USER_PASS}"
      DB_MYSQL_NAME: "${DB_NAME}"
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
DOCKERCOMPOSE

# 9) Start HA stack
echo "==> Starting Docker Compose stack..."
docker-compose up -d
systemctl restart keepalived
systemctl restart syncthing@root

# 10) Generate Galera config
echo "==> Generating Galera config..."
cat >"${MYSQL_CONF_DIR}/galera.cnf" <<'GALERA'
[mysqld]
wsrep_on=ON
wsrep_provider=/usr/lib/galera/libgalera_smm.so
wsrep_cluster_address="gcomm://${HOST_IP},${PEER_IPS}"
wsrep_cluster_name="${CLUSTER_NAME}"
wsrep_node_address="${HOST_IP}"
wsrep_node_name="$(hostname)"
wsrep_sst_method=xtrabackup-v2
GALERA

# 11) Generate Keepalived config
echo "==> Generating Keepalived config..."
cat >"${KEEPALIVED_CONF_DIR}/keepalived.conf" <<'KEEPALIVED'
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
KEEPALIVED

# 12) Generate Syncthing config
echo "==> Generating Syncthing config..."
cat >"${SYNCTHING_CONF_DIR}/config.xml" <<'SYNC'
<configuration version="32">
  <device id="${SYNCTHING_DEVICE_ID}" name="$(hostname)" compression="metadata" introducer="false" />
SYNC
IFS=',' read -ra PIDS <<<"${SYNCTHING_PEER_DEVICE_IDS}"
cat >>"${SYNCTHING_CONF_DIR}/config.xml" <<'FOLDER_START'
  <folder id="npm-data" label="npm-data" path="${DATA_DIR}" type="sendreceive">
FOLDER_START
for pid in "${PIDS[@]}"; do
  echo "    <device id=\"${pid}\" />" >>"${SYNCTHING_CONF_DIR}/config.xml"
done
cat >>"${SYNCTHING_CONF_DIR}/config.xml" <<'FOLDER_END'
    <ignoreDelete>false</ignoreDelete>
    <fsWatcherEnabled>true</fsWatcherEnabled>
    <rescanIntervalS>1</rescanIntervalS>
  </folder>
FOLDER_END
cat >>"${SYNCTHING_CONF_DIR}/config.xml" <<'FOLDER_START'
  <folder id="letsencrypt" label="letsencrypt" path="${LETSENCRYPT_DIR}" type="sendreceive">
FOLDER_START
for pid in "${PIDS[@]}"; do
  echo "    <device id=\"${pid}\" />" >>"${SYNCTHING_CONF_DIR}/config.xml"
done
cat >>"${SYNCTHING_CONF_DIR}/config.xml" <<'FOLDER_END'
    <ignoreDelete>false</ignoreDelete>
    <fsWatcherEnabled>true</fsWatcherEnabled>
    <rescanIntervalS>1</rescanIntervalS>
  </folder>
</configuration>
FOLDER_END

# 13) Generate README.md
echo "==> Generating README.md..."
cat >README.md <<'README'
# Cloud-Proxy HA Setup

This directory contains everything needed to stand up a two-node, high-availability
Nginx Proxy Manager cluster. Configs are generated by **setup-ha.sh**:

- **MariaDB Galera Cluster**
- **Keepalived** for floating-IP failover
- **Syncthing** for bidirectional sync of `/opt/npm-data` and Let’s Encrypt certs

Source repo: https://github.com/jsbrain/cloud-proxy.git

## Dependencies

Install these packages on each host:

- keepalived
- syncthing
- curl
- jq
- apt-transport-https
- ca-certificates
- gnupg

---

## Quickstart

1. **Clone** the repository on each host:

   ```bash
   git clone https://github.com/jsbrain/cloud-proxy.git
   cd cloud-proxy
   ```

2. **Make the setup script executable** and run it:

   ```bash
   chmod +x setup-ha.sh
   ./setup-ha.sh
   ```

3. **Bring up the HA stack**:

   ```bash
   docker-compose up -d
   systemctl restart keepalived
   systemctl restart syncthing@root
   ```

---

## Environment Variables (Examples)

All required values can be set as environment variables before running the script. Use inline exports or a `.env` file:

### Inline Exports
```bash
export HOST_IP="10.0.0.2"
export PEER_IPS="10.0.0.2,10.0.0.3"
export FLOATING_IP="10.0.0.100"
export ROLE="MASTER"               # or BACKUP
export PRIORITY="150"              # MASTER > BACKUP
export SYNCTHING_DEVICE_ID="ABC123DEVICEID"
export SYNCTHING_PEER_DEVICE_IDS="DEF456,GHI789"

# Optional overrides:
export DB_ROOT_PASS="myRootPass"
export DB_PORT="3306"
export DB_USER="npm"
export DB_USER_PASS="npmPass"
export DB_NAME="npm"
export CLUSTER_NAME="npm-galera"
export XTRABACKUP_PASSWORD="xbckPass"

chmod +x setup-ha.sh
./setup-ha.sh
```

### `.env` File
```dotenv
HOST_IP=10.0.0.2
PEER_IPS=10.0.0.2,10.0.0.3
FLOATING_IP=10.0.0.100
ROLE=MASTER
PRIORITY=150
SYNCTHING_DEVICE_ID=ABC123DEVICEID
SYNCTHING_PEER_DEVICE_IDS=DEF456,GHI789

# Optional overrides:
DB_ROOT_PASS=myRootPass
DB_PORT=3306
DB_USER=npm
DB_USER_PASS=npmPass
DB_NAME=npm
CLUSTER_NAME=npm-galera
XTRABACKUP_PASSWORD=xbckPass
```

Then:
```bash
export $(grep -v '^#' .env | xargs)
chmod +x setup-ha.sh
./setup-ha.sh
```

---

## Environment Variable Reference

| Variable                    | Description                                                |
| --------------------------- | ---------------------------------------------------------- |
| `HOST_IP`                   | this host’s IP                                             |
| `PEER_IPS`                  | comma-separated peer IPs                                   |
| `FLOATING_IP`               | floating IP for VRRP                                       |
| `ROLE`                      | Keepalived role (`MASTER` or `BACKUP`)                     |
| `PRIORITY`                  | VRRP priority (150=MASTER,100=BACKUP)                      |
| `SYNCTHING_DEVICE_ID`       | this host’s Syncthing Device ID                            |
| `SYNCTHING_PEER_DEVICE_IDS` | comma-separated peer Syncthing Device IDs                 |
| `DB_ROOT_PASS`              | MariaDB root password (required)                           |
| `DB_PORT`                   | MariaDB port for local binding (default: 3306)             |
| `DB_USER`                   | MariaDB user name (required)                               |
| `DB_USER_PASS`              | MariaDB user password (required)                           |
| `DB_NAME`                   | MariaDB database name (required)                           |
| `CLUSTER_NAME`              | Galera cluster name (required)                             |
| `XTRABACKUP_PASSWORD`       | XtraBackup password (required)                             |
| `LETSENCRYPT_DIR`           | path to Let’s Encrypt data (required)                      |
| `PUID`                      | NPM container user ID                                      |
| `PGID`                      | NPM container group ID                                     |

---

## Management & Monitoring

### Docker Compose
```bash
docker-compose ps
docker-compose logs npm-app
make logs npm-db
```

### Keepalived
```bash
systemctl status keepalived
journalctl -u keepalived -f
grep VRRP /var/log/syslog
```

### Syncthing
```bash
systemctl status syncthing@root
journalctl -u syncthing@root -f
syncthing cli config devices list
```

### Galera Cluster
```bash
docker exec -it npm-db mysql -uroot -p"${DB_ROOT_PASS}" \
  -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
docker exec -it npm-db mysql -uroot -p"${DB_ROOT_PASS}" \
  -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
```
README

EOF

echo "==> All done! See README.md for full details."
