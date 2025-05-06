# Zoraxy HA Installer

## Overview

The Zoraxy HA Installer is a unified bash script that automates the deployment of a high-availability Zoraxy cluster on Debian 12. It can:

- Initialize a **Master** node (with optional immediate replica addition).  
- Add additional **Replica** nodes to an existing Master.  
- Deploy and configure Docker, Docker Compose, Zoraxy services, Keepalived VRRP, and a file-watch “watch-and-sync” mechanism.  

This single-script installer handles all prerequisites, configuration files, systemd units, and SSH key distribution needed to get a two-node (or larger) HA cluster up and running with minimal interaction.

---

## Prerequisites

- **OS:** Debian 12 (or compatible)  
- **Root access:** Must run as root (`EUID == 0`)  
- **Network:**  
  - Static IPs configured on each node  
  - SSH between Master and Replica(s)  
- **Ports:**  
  - TCP 22 (SSH)  
  - VRRP protocol (IP 112) for Keepalived  
  - Any ports used by Zoraxy’s Docker stack  

---

## Installation

1. **Download the script** to your Master node:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/OzzyGava/zoraxy-ha/refs/heads/main/zoraxy-ha-installer.sh -o zoraxy-ha-installer.sh
   chmod +x zoraxy-ha_installer.sh
   ```

2. **Run the installer** interactively on the Master:
   ```bash
   ./zoraxy-ha_installer.sh
   ```
   You’ll be prompted to choose one of three modes:
   1. Initialize a new HA cluster (Primary)  
   2. Initialize a new HA cluster and add a replica  
   3. Add Replica (to an existing Master)  

---

## Usage & Modes

### Interactive Master Setup

    ./zoraxy-ha_installer.sh

1. Select operation mode  
2. Install Docker & Compose  
3. Deploy Zoraxy stack  
4. Choose traffic & HA heartbeat interfaces  
5. Enter your VIP & Keepalived password  
6. Install core packages (`rsync`, `inotify-tools`, etc.)  
7. Configure & start Keepalived  
8. Deploy file-watch “watch-and-sync” service  
9. (Optional) Add Replica — SSH keys, copy script, invoke replica install, update peers file  

## Internals & File Layout

- **`/opt/zoraxy/`**  
  - `docker-compose.yml` — Zoraxy stack  
  - `ha-env.conf`      — saved interface/VIP/PASS for replica additions  
  - `ha-sync-peers.txt`— list of peer IPs for sync  
  - `scripts/watch-and-sync.sh` — inotify-based sync script  
  - `logs/ha-sync.log` — sync service log  

- **Keepalived**  
  - `/etc/keepalived/keepalived.conf` — VRRP configuration  
  - Systemd unit enabled on install  

- **HA Sync Service** (systemd)  
  - Watches `/opt/zoraxy/config` for changes in `conf/`, `www/`, `sys.db`.  
  - Debounces events for 60 seconds.  
  - Pushes updates via `rsync` to each IP in `ha-sync-peers.txt`.  
  - Restarts the Docker stack on each peer.  

---

## Adding More Replicas

After initial Master setup, choose **“Add Replica”** from the menu (option 3)

    ./zoraxy-ha_installer.sh
    # select option 3 → add replica IP & user

The script will:

1. SSH-copy your public key (single password prompt).  
2. Upload the same installer to the new Replica.  
3. Invoke it in `--replica` mode (interactive network selection).  
4. Append the new IP to `/opt/zoraxy/ha-sync-peers.txt`.  

---

## Logs & Troubleshooting

- **Installer log:** Console output  
- **Sync log:** `/opt/zoraxy/logs/ha-sync.log`  
- **Keepalived status:** `systemctl status keepalived`  
- **Sync service status:** `systemctl status zoraxy-ha-sync.service`  

**Common errors**  
- **“VIP unbound variable”** → ensure you run network phase on Master first, enter VIP & PASS.  
- **SSH prompts twice** → fixed in v14: only one password prompt on `ssh-copy-id`. 
