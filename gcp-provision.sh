#!/usr/bin/env bash

set -e

echo "===================================================="
echo " GCP Compute Engine - Deploy e2-micro (Always Free) "
echo "===================================================="
echo ""

# 1. Project Selection with Numbered Menu and Input Validation
echo "Fetching available GCP projects..."
mapfile -t PROJECTS < <(gcloud projects list --format="value(projectNumber, projectId, name)" 2>/dev/null)

if [ ${#PROJECTS[@]} -eq 0 ]; then
  echo "ERROR: No GCP projects found or 'gcloud' is not authenticated." >&2
  exit 1
fi

echo ""
echo "Select a GCP project from the list below:"
for i in "${!PROJECTS[@]}"; do
  num=$((i + 1))
  # Extracts the Project ID from the returned list
  proj_id=$(echo "${PROJECTS[$i]}" | awk '{print $2}')
  proj_name=$(echo "${PROJECTS[$i]}" | awk '{$1=""; $2=""; print $0}' | sed 's/^[ \t]*//')
  echo "  [$num] $proj_id ($proj_name)"
done

echo ""
SELECTED_PROJECT=""
while true; do
  read -p "Enter project number [1-${#PROJECTS[@]}]: " MENU_CHOICE
  if [[ "$MENU_CHOICE" =~ ^[0-9]+$ ]] && [ "$MENU_CHOICE" -ge 1 ] && [ "$MENU_CHOICE" -le "${#PROJECTS[@]}" ]; then
    INDEX=$((MENU_CHOICE - 1))
    SELECTED_PROJECT=$(echo "${PROJECTS[$INDEX]}" | awk '{print $2}')
    break
  else
    echo "Invalid selection. Please enter a number between 1 and ${#PROJECTS[@]}."
  fi
done

echo "Setting active project to: $SELECTED_PROJECT"
gcloud config set project "$SELECTED_PROJECT" --quiet

echo ""
# 2. Instance Name Input Validation
while true; do
  read -p "Enter Instance Name [default: freepbx-vm]: " INSTANCE_NAME
  INSTANCE_NAME=${INSTANCE_NAME:-freepbx-vm}
  # Validate RFC 1035 name constraint for GCP instances (lowercase, numbers, hyphens)
  if [[ "$INSTANCE_NAME" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]]; then
    break
  else
    echo "Invalid instance name. Must start with a lowercase letter, contain only lowercase letters, numbers, hyphens, and end with an alphanumeric character."
  fi
done

# 3. Region Input Validation
while true; do
  read -p "Enter Region [default: us-central1]: " REGION
  REGION=${REGION:-us-central1}
  if [[ "$REGION" =~ ^[a-z]+-[a-z]+[0-9]+$ ]]; then
    break
  else
    echo "Invalid region format. Example: us-central1, us-west1, us-east1."
  fi
done

ZONE="${REGION}-a"

echo ""
echo "----------------------------------------------------"
echo " Selected Configuration:"
echo " - GCP Project: $SELECTED_PROJECT"
echo " - Instance:    $INSTANCE_NAME"
echo " - Region:      $REGION ($ZONE)"
echo " - Machine:     e2-micro (Always Free Tier)"
echo " - Disk:        30 GB Standard Persistent Disk (Debian 12)"
echo "----------------------------------------------------"

while true; do
  read -p "Do you want to proceed with creation? (y/n): " CONFIRM
  CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
  if [[ "$CONFIRM" == "y" || "$CONFIRM" == "yes" ]]; then
    break
  elif [[ "$CONFIRM" == "n" || "$CONFIRM" == "no" ]]; then
    echo "Deployment aborted by user."
    exit 0
  else
    echo "Invalid input. Please enter 'y' or 'n'."
  fi
done

echo ""
echo "=== 1. Creating Firewall Rules for FreePBX / SIP / RTP ==="

# HTTP/HTTPS Web Rules
gcloud compute firewall-rules create allow-freepbx-web \
  --allow=tcp:80,tcp:443 \
  --description="FreePBX HTTP and HTTPS Web ports" \
  --direction=INGRESS --quiet 2>/dev/null || echo "Rule allow-freepbx-web already exists."

# SIP Signaling Rules
gcloud compute firewall-rules create allow-freepbx-sip \
  --allow=udp:5060,udp:5160 \
  --description="Asterisk SIP signaling ports" \
  --direction=INGRESS --quiet 2>/dev/null || echo "Rule allow-freepbx-sip already exists."

# RTP Media Stream Rule
gcloud compute firewall-rules create allow-freepbx-rtp \
  --allow=udp:16384-32767 \
  --description="RTP Media port range for audio" \
  --direction=INGRESS --quiet 2>/dev/null || echo "Rule allow-freepbx-rtp already exists."

echo ""
echo "=== 2. Creating e2-micro Compute Instance ==="

STARTUP_SCRIPT=$(cat << 'EOF'
#!/usr/bin/env bash
set -e

# Configure 2GB Swap file for RAM stability
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# Install Docker prerequisites
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release iptables

if ! command -v docker &> /dev/null; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io
  systemctl enable docker
  systemctl start docker
fi
EOF
)

gcloud compute instances create "$INSTANCE_NAME" \
  --zone="$ZONE" \
  --machine-type="e2-micro" \
  --network-interface="network-tier=STANDARD,subnet=default" \
  --metadata=startup-script="$STARTUP_SCRIPT" \
  --maintenance-policy="MIGRATE" \
  --provisioning-model="STANDARD" \
  --image-family="debian-12" \
  --image-project="debian-cloud" \
  --boot-disk-size="30GB" \
  --boot-disk-type="pd-standard" \
  --boot-disk-device-name="$INSTANCE_NAME" \
  --tags="http-server,https-server"

echo ""
echo "===================================================="
echo " Instance deployed successfully!"
echo "===================================================="
echo " To connect to the instance via SSH, execute:"
echo "   gcloud compute ssh $INSTANCE_NAME --zone=$ZONE"
echo ""
echo " Docker installation and SWAP configuration are running in the background."
echo " Once connected, you can execute your 'run-gcp.sh' script."
