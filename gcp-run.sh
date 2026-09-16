#!/usr/bin/env bash

set -euo pipefail

# Resolve secrets relative to this script so execution does not depend on the current directory.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

read_secret() {
  local variable_name="$1"
  local file_name="$2"
  local value="${!variable_name:-}"

  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi

  if [[ -f "$SCRIPT_DIR/$file_name" ]]; then
    cat "$SCRIPT_DIR/$file_name"
    return 0
  fi

  echo "ERROR: Neither environment variable '$variable_name' nor secret file '$SCRIPT_DIR/$file_name' is available." >&2
  return 1
}

# GCP and Container settings
IMAGE_NAME="ghcr.io/weslleymurdock/fpbx:latest"
CONTAINER_NAME="freepbx-app"
FREEPBX_IP="172.18.0.20"
RTP_PORT_RANGE="10000-20000"
NETWORK_NAME="freepbx-net"
FREEPBX_PWD="$(read_secret FREEPBX_DB_PASSWORD freepbxuser_password.txt)"
MYSQL_ROOT_PASSWORD="$(read_secret MYSQL_ROOT_PASSWORD mysql_root_password.txt)"
ASTERISK_ADMIN_PASSWORD="$(read_secret ADMIN_PASSWORD admin_password.txt)"

get_default_iface() {
  ip -o -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
}

DEFAULT_IFACE="$(get_default_iface)"

if [[ -z "$DEFAULT_IFACE" ]]; then
  echo "ERROR: Was not possible detect the default network interface at host." >&2
  exit 1
fi

requested_rtp=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--rtp" ]]; then
    requested_rtp="$arg"
    prev=""
    continue
  fi
  case "$arg" in
    --rtp) prev="--rtp" ;;
  esac
done

if [[ -n "$requested_rtp" ]]; then
  if [[ "$requested_rtp" =~ ^[0-9]+-[0-9]+$ ]]; then
    start_port="${requested_rtp%%-*}"
    end_port="${requested_rtp##*-}"
    if (( end_port > start_port )); then
      RTP_PORT_RANGE="$requested_rtp"
    else
      echo "ERROR: invalid value for --rtp. The upper-limit must be bigger." >&2
      exit 1
    fi
  else
    echo "ERROR: invalid value for --rtp. Use START-END." >&2
    exit 1
  fi
fi

# ACTION: INSTALL FREEPBX
if [[ "$*" == *"--install-freepbx"* ]]; then
  echo "Running the FreePBX installer inside the container..."

  if ! sudo docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "ERROR: Container '$CONTAINER_NAME' does not exist." >&2
    exit 1
  fi

  if ! sudo docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" | grep -q '^true$'; then
    echo "ERROR: Container '$CONTAINER_NAME' is not running." >&2
    exit 1
  fi

  echo "Checking MariaDB readiness..."
  for _ in $(seq 1 30); do
    if sudo docker exec "$CONTAINER_NAME" mysqladmin --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" ping --silent >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ! sudo docker exec "$CONTAINER_NAME" mysqladmin --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" ping --silent >/dev/null 2>&1; then
    echo "ERROR: MariaDB inside '$CONTAINER_NAME' did not become ready with the configured root password." >&2
    exit 1
  fi

  if ! sudo docker exec "$CONTAINER_NAME" test -x /usr/local/src/freepbx/install; then
    echo "ERROR: FreePBX installer was not found at /usr/local/src/freepbx/install inside the image." >&2
    exit 1
  fi

  if sudo docker exec "$CONTAINER_NAME" test -f /etc/freepbx.conf; then
    echo "FreePBX is already installed (/etc/freepbx.conf exists). Nothing to do."
    exit 0
  fi

  sudo docker exec \
    -e FREEPBX_DB_PASSWORD="$FREEPBX_PWD" \
    "$CONTAINER_NAME" \
    bash -c 'cd /usr/local/src/freepbx && php ./install -n --dbuser=freepbxuser --dbpass="$FREEPBX_DB_PASSWORD" --dbhost=127.0.0.1'

  echo "Running FreePBX post-install initialization..."
  sudo docker exec "$CONTAINER_NAME" fwconsole chown
  sudo docker exec "$CONTAINER_NAME" fwconsole reload
  sudo docker exec "$CONTAINER_NAME" fwconsole restart
  echo "FreePBX installation completed."
  exit 0

# ACTION: CLEAN ALL
elif [[ "$*" == *"--clean-all"* ]]; then
  read -r -p "Deleting containers, volumes and local firewall rules. Are you sure? (yes/no): " confirmation
  if [[ "$confirmation" != "yes" ]]; then
    echo "Cancelled."
    exit 0
  fi

  echo "Removing systemd service, containers and networks..."
  sudo systemctl stop freepbx-docker.service 2>/dev/null || true
  sudo systemctl disable freepbx-docker.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/freepbx-docker.service
  sudo systemctl daemon-reload

  sudo docker stop "$CONTAINER_NAME" 2>/dev/null || true
  sudo docker rm "$CONTAINER_NAME" 2>/dev/null || true
  sudo docker volume rm freepbx_var_data freepbx_etc_data 2>/dev/null || true
  sudo docker network rm "$NETWORK_NAME" 2>/dev/null || true

  echo "Cleanup successfully finished."
  exit 0

# ACTION: DEPLOY GCP
else
  echo "=== 1. Allowing firewall ports at GCP VPC ==="
  if command -v gcloud &> /dev/null; then
    echo "Setting up new rules at GCP Cloud Firewall through gcloud..."
    gcloud compute firewall-rules create allow-freepbx-web \
      --allow=tcp:80,tcp:443 \
      --description="Portas Web do FreePBX" \
      --direction=INGRESS --quiet 2>/dev/null || echo "Regra allow-freepbx-web já existe."

    gcloud compute firewall-rules create allow-freepbx-sip \
      --allow=udp:5060,udp:5160 \
      --description="Portas SIP Asterisk" \
      --direction=INGRESS --quiet 2>/dev/null || echo "Regra allow-freepbx-sip já existe."

    gcloud compute firewall-rules create allow-freepbx-rtp \
      --allow="udp:${RTP_PORT_RANGE}" \
      --description="Intervalo de Portas RTP para Áudio" \
      --direction=INGRESS --quiet 2>/dev/null || echo "Regra allow-freepbx-rtp já existe."
  else
    echo "WARNING: 'gcloud' CLI not found at host. Ensure to free up TCP 80, 443 e UDP 5060, 5160, ${RTP_PORT_RANGE} manually at Console GCP."
  fi

  echo "=== 2. Applying local iptable rules for NAT/RTP ==="
  if ! sudo iptables -C DOCKER-USER -p udp -d "$FREEPBX_IP" --dport "${RTP_PORT_RANGE/-/:}" -j ACCEPT 2>/dev/null; then
    sudo iptables -I DOCKER-USER -p udp -d "$FREEPBX_IP" --dport "${RTP_PORT_RANGE/-/:}" -j ACCEPT
    echo "Rule DOCKER-USER for RTP traffic added."
  fi

  if ! sudo iptables -t nat -C PREROUTING -i "$DEFAULT_IFACE" -p udp --dport "${RTP_PORT_RANGE/-/:}" \
      -j DNAT --to-destination "$FREEPBX_IP:${RTP_PORT_RANGE/:/-}" 2>/dev/null; then
    sudo iptables -t nat -A PREROUTING -i "$DEFAULT_IFACE" -p udp --dport "${RTP_PORT_RANGE/-/:}" \
      -j DNAT --to-destination "$FREEPBX_IP:${RTP_PORT_RANGE/:/-}"
    echo "Rule Destination NAT RTP add at interface $DEFAULT_IFACE."
  fi

  echo "=== 3. Preparing Network and Docker Volumes ==="
  sudo docker network create --driver bridge --subnet 172.18.0.0/16 "$NETWORK_NAME" 2>/dev/null || true
  sudo docker volume create freepbx_var_data 2>/dev/null || true
  sudo docker volume create freepbx_etc_data 2>/dev/null || true
  sudo docker volume create freepbx_mysql_data 2>/dev/null || true

  echo "=== 4. Configuring native Systemd Service ==="
  cat <<EOF | sudo tee /etc/systemd/system/freepbx-docker.service > /dev/null
[Unit]
Description=Docker FreePBX / Asterisk
After=docker.service
Requires=docker.service

[Service]
TimeoutStartSec=0
Restart=always

ExecStartPre=/bin/sh -c '/usr/bin/docker stop ${CONTAINER_NAME} 2>/dev/null || true'
ExecStartPre=/bin/sh -c '/usr/bin/docker rm ${CONTAINER_NAME} 2>/dev/null || true'
ExecStartPre=/usr/bin/docker pull ${IMAGE_NAME}
ExecStart=/usr/bin/docker run --name ${CONTAINER_NAME} \
  --privileged \
  --ulimit rtprio=99 \
  --ulimit nice=-19 \
  --net ${NETWORK_NAME} \
  --ip ${FREEPBX_IP} \
  -e MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD} \
  -e FREEPBX_DB_PASSWORD=${FREEPBX_PWD} \
  -e ADMIN_PASSWORD=${ASTERISK_ADMIN_PASSWORD} \
  -p 8080:80 \
  -p 8443:443 \
  -p 5060:5060/udp \
  -p 5160:5160/udp \
  -v freepbx_var_data:/var/lib/asterisk \
  -v freepbx_etc_data:/etc/asterisk \
  -v freepbx_mysql_data:/var/lib/mysql \
  ${IMAGE_NAME}
ExecStop=/usr/bin/docker stop ${CONTAINER_NAME}

[Install]
WantedBy=multi-user.target
EOF

  echo "=== 5. Activating and Starting the Service ==="
  sudo systemctl daemon-reload
  sudo systemctl enable freepbx-docker.service
  sudo systemctl restart freepbx-docker.service
  echo "Waiting container initialization..."
  sleep 5
  sudo systemctl status freepbx-docker.service --no-pager
  sleep 5
  docker logs ${CONTAINER_NAME}
  echo "Deploy done! The service is registered at Systemd and will be restarted automatically with OS."
fi
