#!/usr/bin/env bash

set -e

# GCP and Container settings
IMAGE_NAME="ghcr.io/weslleymurdock/fpbx:17-gcp-minimal-rc-1"
CONTAINER_NAME="freepbx-app"
FREEPBX_IP="172.18.0.20"
RTP_PORT_RANGE="16384-32767"
NETWORK_NAME="freepbx-net"

# Detects the default network interface at host
get_default_iface() {
  ip -o -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
}

DEFAULT_IFACE="$(get_default_iface)"

if [[ -z "$DEFAULT_IFACE" ]]; then
  echo "ERROR: Was not possible detect the default network interface at host." >&2
  exit 1
fi

# --rtp flag treatment
requested_rtp=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--rtp" ]]; then
    requested_rtp="$arg"
    prev=""
    continue
  fi
  case "$arg" in
    --rtp)
      prev="--rtp"
      ;;
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
  fi
fi

# ACTION: INSTALL FREEPBX
if [[ "$*" == *"--install-freepbx"* ]]; then
  echo "Running the installer inside the container..."
  sudo docker exec -it -w /usr/local/src/freepbx "$CONTAINER_NAME" php install -n --dbuser=freepbxuser --dbpass="$(cat freepbxuser_password.txt)" --dbhost=db
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
  # Rule DOCKER-USER
  if ! sudo iptables -C DOCKER-USER -p udp -d "$FREEPBX_IP" --dport "${RTP_PORT_RANGE/-/:}" -j ACCEPT 2>/dev/null; then
    sudo iptables -I DOCKER-USER -p udp -d "$FREEPBX_IP" --dport "${RTP_PORT_RANGE/-/:}" -j ACCEPT
    echo "Rule DOCKER-USER for RTP traffic added."
  fi

  # Rule PREROUTING NAT
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

  echo "=== 4. Configuring native Systemd Service ==="
  # Creates the systemd service file to manage the persistence at boot/crash
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
  --net ${NETWORK_NAME} \
  --ip ${FREEPBX_IP} \
  -p 8080:80 \
  -p 8443:443 \
  -p 5060:5060/udp \
  -p 5160:5160/udp \
  -v freepbx_var_data:/var/lib/asterisk \
  -v freepbx_etc_data:/etc/asterisk \
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
  
  echo "Deploy done! The service is registered at Systemd and will be restarted automatically with OS."
fi
