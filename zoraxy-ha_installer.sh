#!/bin/bash
set -euo pipefail
#
# Built with smashing keyboard against chatGPT and using some of my brain.

# Paths
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"

# Colors
RESET=$'\e[0m'; INFO=$'\e[1;34m'; OK=$'\e[1;32m'; WARN=$'\e[1;33m'; ERROR=$'\e[1;31m'

# Must be root
(( EUID == 0 )) || { echo -e "${ERROR}Please run as root.${RESET}"; exit 1; }

# Cleanup on errors
cleanup() {
  echo -e "${WARN}Cleaning up…${RESET}"
  systemctl disable zoraxy-ha-sync.service keepalived &>/dev/null || true
  systemctl stop    zoraxy-ha-sync.service keepalived &>/dev/null || true
  rm -rf /opt/zoraxy
  rm -f /etc/keepalived/keepalived.conf \
        /etc/systemd/system/zoraxy-ha-sync.service \
        /etc/logrotate.d/zoraxy-ha-sync
}
trap cleanup ERR

# Usage
usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--replica TRAFFIC_IF HA_IF VIP PASS] [--vrid N] [--dry-run] [-h|--help]
  --replica    install on a replica (noninteractive)
  --vrid N      Keepalived VRID (default: 51)
  --dry-run     show actions without making changes
  -h, --help    display this help
EOF
}

# Defaults
MODE="MASTER"
DRY_RUN=0
VRID=51
ADD_REPLICA=false
SKIP_MASTER_SETUP=false

# Parse flags
while [[ $# -gt 0 ]]; do
  case $1 in
    --replica)
      MODE="REPLICA"; TRAFFIC_IF=$2; HA_IF=$3; HA_VIP=$4; HA_PASS=$5
      shift 5 ;;
    --vrid)
      VRID=$2; shift 2 ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo -e "${ERROR}Unknown option: $1${RESET}" >&2
      usage; exit 1 ;;
  esac
done

ROLE_LABEL="[${MODE}]"

install_packages(){
  echo -n "${ROLE_LABEL} ${INFO}Installing: $*…${RESET} "
  if (( DRY_RUN==0 )); then
    apt update -qq &>/dev/null
    apt install -y "$@" &>/dev/null \
      && echo -e " ${OK}done${RESET}" \
      || { echo -e " ${ERROR}fail${RESET}"; exit 1; }
  else
    echo -e " ${WARN}skipped${RESET}"
  fi
}

spinner(){
  local pid=$1 delay=0.1 frames=('|' '/' '-' '\')
  while kill -0 "$pid" 2>/dev/null; do
    for f in "${frames[@]}"; do
      printf "\b%s" "$f"
      sleep "$delay"
    done
  done
  printf "\b"
}

# Phase 1: Mode selection
phase_select_node(){
  [[ "$MODE" == "REPLICA" ]] && return
  echo
  echo "${ROLE_LABEL} Select operation mode:"
  echo "  [1] Initialize a new HA cluster (Primary)"
  echo "  [2] Initialize a new HA cluster and add a replica"
  echo "  [3] Add Replica"
  read -rp "${ROLE_LABEL} Enter [1-3]: " c
  case $c in
    1) ADD_REPLICA=false ;;
    2) ADD_REPLICA=true  ;;
    3) ADD_REPLICA=true; SKIP_MASTER_SETUP=true ;;
    *) echo -e "${ERROR}Invalid choice.${RESET}"; exit 1 ;;
  esac
}

# Phase 1b: Tag shell prompt
phase_prompt(){
  local tag="[${MODE}]"
  grep -qxF "export PS1=\"$tag \\u@\\h:\\w\\$ \"" /root/.bashrc \
    || echo "export PS1=\"$tag \\u@\\h:\\w\\$ \"" >> /root/.bashrc
}

# Phase 2: Docker & Compose
phase_install_docker(){
  echo -e "${ROLE_LABEL} ${INFO}Verifying Docker…${RESET}"
  if ! command -v docker &>/dev/null; then
    install_packages curl
    echo -n "${ROLE_LABEL} ${INFO}Installing Docker…${RESET}"
    (curl -fsSL https://get.docker.com | sh) &>/dev/null & spinner $! && echo -e " ${OK}done${RESET}"
  else
    echo -e "${ROLE_LABEL} ${OK}Docker present${RESET}"
  fi
  echo -e "${ROLE_LABEL} ${INFO}Verifying Compose…${RESET}"
  if ! docker compose version &>/dev/null; then
    install_packages docker-compose-plugin
  else
    echo -e "${ROLE_LABEL} ${OK}Compose present${RESET}"
  fi
}

# Phase 3: Deploy Zoraxy
phase_deploy_zoraxy(){
  install_packages curl
  echo -n "${ROLE_LABEL} ${INFO}Installing Zoraxy…${RESET}"
  if [[ ! -f /opt/zoraxy/docker-compose.yml ]]; then
    mkdir -p /opt/zoraxy
    curl -fsSL https://raw.githubusercontent.com/tobychui/zoraxy/refs/heads/main/docker/docker-compose.yml \
      -o /opt/zoraxy/docker-compose.yml
    sed -i 's|/path/to/zoraxy|/opt/zoraxy|g' /opt/zoraxy/docker-compose.yml
    echo -e " ${OK}done${RESET}"
  else
    echo -e " ${OK}already present${RESET}"
  fi
  echo -n "${ROLE_LABEL} ${INFO}Pulling images…${RESET}"
  (cd /opt/zoraxy && docker compose pull) &>/dev/null & spinner $! && echo -e " ${OK}pulled${RESET}"
  echo -n "${ROLE_LABEL} ${INFO}Starting stack…${RESET}"
  (cd /opt/zoraxy && docker compose up -d) &>/dev/null & spinner $! && echo -e " ${OK}running${RESET}"
}

# Phase 4: Improved network selection
phase_network(){
  declare -A IFADDR
  while read -r iface _ addr _; do IFADDR[$iface]=$addr; done < <(ip -br a)
  mapfile -t IFACES < <(printf "%s\n" "${!IFADDR[@]}" | sort)

  echo -e "${ROLE_LABEL} ${INFO}Available interfaces:${RESET}"
  for i in "${!IFACES[@]}"; do
    printf "  %2d) %-12s %s\n" $((i+1)) "${IFACES[i]}" "${IFADDR[${IFACES[i]}]}"
  done

  read -rp "${ROLE_LABEL} Select traffic interface [1-${#IFACES[@]}]: " sel
  TRAFFIC_IF=${IFACES[sel-1]}
  read -rp "${ROLE_LABEL} Select HA heartbeat interface [1-${#IFACES[@]}]: " sel
  HA_IF=${IFACES[sel-1]}
}

# Phase 5: Core packages
phase_core(){
  install_packages rsync
  if [[ "$MODE" == "MASTER" ]]; then
    install_packages inotify-tools jq iputils-ping net-tools
    mkdir -p /opt/zoraxy/{scripts,logs}
    touch /opt/zoraxy/ha-sync-peers.txt
    printf "log/\ntmp/\nsys.uuid\n" > /opt/zoraxy/scripts/.rsync-exclude
  fi
  install_packages keepalived
}

# Phase 6: Keepalived
phase_keepalived(){
  echo -n "${ROLE_LABEL} ${INFO}Configuring Keepalived…${RESET}"
  cat <<EOF >/etc/keepalived/keepalived.conf
vrrp_instance VI_1 {
    state $( [[ "$MODE" == "MASTER" ]] && echo MASTER || echo BACKUP )
    interface $TRAFFIC_IF
    virtual_router_id $VRID
    priority $( [[ "$MODE" == "MASTER" ]] && echo 100 || echo 90 )
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass $HA_PASS
    }
    virtual_ipaddress { $HA_VIP }
}
EOF
  echo -e " ${OK}done${RESET}"

  # Save for replica adds
  cat <<EOF >/opt/zoraxy/ha-env.conf
TRAFFIC_IF=$TRAFFIC_IF
HA_IF=$HA_IF
HA_VIP=$HA_VIP
HA_PASS=$HA_PASS
EOF

  echo -n "${ROLE_LABEL} ${INFO}Starting Keepalived…${RESET}"
  systemctl enable --now keepalived &>/dev/null && echo -e " ${OK}started${RESET}"
}

# Phase 7: HA sync (master only)
phase_ha_sync(){
  [[ "$MODE" == "MASTER" ]] || return
  echo -n "${ROLE_LABEL} ${INFO}Deploying HA sync…${RESET}"
  cat <<'EOF' >/opt/zoraxy/scripts/watch-and-sync.sh
#!/bin/bash
set -euo pipefail
SOURCE_DIR="/opt/zoraxy/config"
PEERS_FILE="/opt/zoraxy/ha-sync-peers.txt"
EXCLUDE_FILE="/opt/zoraxy/scripts/.rsync-exclude"
LOG_FILE="/opt/zoraxy/logs/ha-sync.log"
TIMESTAMP_FILE="/opt/zoraxy/scripts/last-change.timestamp"
DEBOUNCE_TIMEOUT=60
IDLE_LOGGED=0
trap 'pkill -P $$ inotifywait' EXIT
log(){ echo "$(date '+%F %T') $*" >> "$LOG_FILE"; }
[ -e "$TIMESTAMP_FILE" ] || touch "$TIMESTAMP_FILE"
inotifywait -m -r --quiet \
  --exclude '(/log/|/tmp/)' \
  -e modify,create,delete,move \
  --format '%w%f %e' \
  "$SOURCE_DIR" \
  | tee -a "$LOG_FILE" \
  | while read -r F EVENTS; do
      case "$F" in
        "$SOURCE_DIR"/conf/*|"$SOURCE_DIR"/www/*|*/sys.db)
          log "Event: $EVENTS on $F – resetting debounce"
          touch "$TIMESTAMP_FILE"
          ;;
      esac
    done &

while true; do
  if [[ -e "$TIMESTAMP_FILE" ]]; then
    AGE=$(( $(date +%s) - $(stat -c%Y "$TIMESTAMP_FILE") ))
    if (( AGE >= DEBOUNCE_TIMEOUT )); then
      log "Syncing…"
      mapfile -t peers < "$PEERS_FILE"
      for peer in "${peers[@]}"; do
        [[ -z $peer ]] && continue
        rsync -az --delete --exclude-from="$EXCLUDE_FILE" \
          "$SOURCE_DIR"/ root@"$peer":"$SOURCE_DIR"/ >> "$LOG_FILE" 2>&1
        ssh root@"$peer" \
          'cd /opt/zoraxy && docker compose down && docker compose up -d' \
          >> "$LOG_FILE" 2>&1
      done
      rm -f "$TIMESTAMP_FILE"
      IDLE_LOGGED=0
      log "Done."
    elif (( IDLE_LOGGED == 0 )); then
      log "Idle."
      IDLE_LOGGED=1
    fi
  fi
  sleep 5
done
EOF

  chmod +x /opt/zoraxy/scripts/watch-and-sync.sh

  cat <<EOF >/etc/systemd/system/zoraxy-ha-sync.service
[Unit]
Description=Zoraxy HA sync
After=network.target docker.service
ConditionPathExists=/opt/zoraxy/scripts/watch-and-sync.sh

[Service]
Type=simple
ExecStartPre=/usr/bin/touch /opt/zoraxy/scripts/last-change.timestamp
ExecStart=/opt/zoraxy/scripts/watch-and-sync.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now zoraxy-ha-sync.service &>/dev/null && echo -e " ${OK}done${RESET}"
}

# Replica standalone install
phase_install_as_replica(){
  phase_install_docker
  phase_deploy_zoraxy
  phase_network
  phase_core
  phase_keepalived
  echo -e "${ROLE_LABEL} ${OK}Zoraxy HA REPLICA setup complete.${RESET}"
}

# Master add-replica
phase_add_replica_master(){
  source /opt/zoraxy/ha-env.conf
  echo -e "\n${ROLE_LABEL} Provisioning new replica…"
  read -rp "${ROLE_LABEL} Replica IP: " RIP
  read -rp "${ROLE_LABEL} SSH user (default: root): " USER
  USER=${USER:-root}

  echo -n "${ROLE_LABEL} ${INFO}Generating SSH key…${RESET}"
  [[ -f ~/.ssh/id_rsa ]] || ssh-keygen -q -t rsa -N "" -f ~/.ssh/id_rsa
  echo -e " ${OK}done${RESET}"

  echo -n "${ROLE_LABEL} ${INFO}Copying SSH key…${RESET}"
  # remove BatchMode so ssh-copy-id can prompt, and skip host-check on first connect
  ssh-copy-id -o StrictHostKeyChecking=no "${USER}@${RIP}" && echo -e " ${OK}done${RESET}"

  # give the server a moment to write authorized_keys
  sleep 1

  echo -n "${ROLE_LABEL} ${INFO}Uploading installer…${RESET}"
  scp -o StrictHostKeyChecking=no "$SCRIPT_PATH" "${USER}@${RIP}:/tmp/${SCRIPT_NAME}" \
    && echo -e " ${OK}done${RESET}"

  echo -e "${ROLE_LABEL} ${INFO}Running remote install…${RESET}"
  ssh -t -o StrictHostKeyChecking=no "${USER}@${RIP}" bash "/tmp/${SCRIPT_NAME}" --replica \
    "$TRAFFIC_IF" "$HA_IF" "$HA_VIP" "$HA_PASS" \
    && echo -e " ${OK}done${RESET}"


  PEERS_FILE=/opt/zoraxy/ha-sync-peers.txt
  touch "$PEERS_FILE"
  if ! grep -Fxq "$RIP" "$PEERS_FILE"; then
    echo "$RIP" >> "$PEERS_FILE"
    echo -e "${OK}Added replica $RIP to peers file${RESET}"
  else
    echo -e "${WARN}Replica $RIP already in peers file${RESET}"
  fi
}

# Main
main(){
  phase_select_node
  phase_prompt

  if [[ "$MODE" == "REPLICA" ]]; then
    phase_install_as_replica
    exit 0
  fi

  if [[ "$SKIP_MASTER_SETUP" == "true" ]]; then
    phase_add_replica_master
    exit 0
  fi

  # Master full install
  phase_install_docker
  phase_deploy_zoraxy
  phase_network
  phase_core
  phase_ha_sync

  if [[ "$ADD_REPLICA" == "true" ]]; then
    phase_add_replica_master
  else
    phase_keepalived
    echo -e "${ROLE_LABEL} ${OK}Zoraxy HA MASTER setup complete.${RESET}"
  fi
}

main "$@"
