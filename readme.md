# HA Syncthing Setup

This repository contains the **setup-ha.sh** script which installs dependencies and generates configuration files for a high-availability Nginx Proxy Manager setup with:

- MariaDB Galera Cluster
- Keepalived failover (Floating IP)
- Syncthing bidirectional synchronization

## Prerequisites

- Ubuntu 20.04+ with root privileges
- Network connectivity between hosts
- Hetzner CLI configured (`hcloud auth login`)

## Usage

1. Clone the repository on each host.
2. Make the script executable and run it:
   ```bash
   chmod +x setup-ha.sh
   ./setup-ha.sh
   ```

## Environment Variables

| Variable                  | Description                             | Default / Example |
| ------------------------- | --------------------------------------- | ----------------- |
| HOST_IP                   | This host's IP address                  | 10.0.0.2          |
| PEER_IPS                  | Comma-separated peer host IPs           | 10.0.0.2,10.0.0.2 |
| FLOATING_IP               | Floating IP for failover                | 10.0.0.100        |
| ROLE                      | Keepalived VRRP role (MASTER or BACKUP) | MASTER            |
| PRIORITY                  | Keepalived VRRP priority                | 150               |
| SYNCTHING_DEVICE_ID       | This host's Syncthing Device ID         | ABCDEFG12345      |
| SYNCTHING_PEER_DEVICE_IDS | Comma-separated Device IDs of peers     | XYZ987,LMNO456    |
| DB_ROOT_PASS              | MariaDB root password                   | rootPass          |
| DB_USER                   | MariaDB user for NPM                    | npm               |
| DB_USER_PASS              | MariaDB user password                   | npmPass           |
| DB_NAME                   | MariaDB database name                   | npm               |
| CLUSTER_NAME              | Galera cluster name                     | npm-galera        |
| XTRABACKUP_PASSWORD       | XtraBackup password for Galera          | xbckPass          |
