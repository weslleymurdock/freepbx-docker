#!/usr/bin/env bash

set -e

echo "===================================================="
echo " GCP Compute Engine - Reserve Static External IP "
echo "===================================================="
echo ""

# 1. Select GCP Project from list
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
echo "=== Fetching VM instances in project $SELECTED_PROJECT ==="

# 2. Get list of instances with name, zone, and public IP
mapfile -t INSTANCES < <(gcloud compute instances list --format="value(name, zone.basename(), networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null)

if [ ${#INSTANCES[@]} -eq 0 ]; then
  echo "ERROR: No VM instances found in project '$SELECTED_PROJECT'." >&2
  exit 1
fi

SELECTED_VM_NAME=""
SELECTED_VM_ZONE=""
SELECTED_VM_IP=""

if [ ${#INSTANCES[@]} -eq 1 ]; then
  SELECTED_VM_NAME=$(echo "${INSTANCES[0]}" | awk '{print $1}')
  SELECTED_VM_ZONE=$(echo "${INSTANCES[0]}" | awk '{print $2}')
  SELECTED_VM_IP=$(echo "${INSTANCES[0]}" | awk '{print $3}')
  echo "Found single instance: $SELECTED_VM_NAME ($SELECTED_VM_ZONE) - IP: $SELECTED_VM_IP"
else
  echo ""
  echo "Multiple VM instances found. Select which VM to process:"
  for i in "${!INSTANCES[@]}"; do
    num=$((i + 1))
    vm_name=$(echo "${INSTANCES[$i]}" | awk '{print $1}')
    vm_zone=$(echo "${INSTANCES[$i]}" | awk '{print $2}')
    vm_ip=$(echo "${INSTANCES[$i]}" | awk '{print $3}')
    echo "  [$num] $vm_name (Zone: $vm_zone) - Public IP: ${vm_ip:-None}"
  done

  echo ""
  while true; do
    read -p "Enter VM number [1-${#INSTANCES[@]}]: " VM_CHOICE
    if [[ "$VM_CHOICE" =~ ^[0-9]+$ ]] && [ "$VM_CHOICE" -ge 1 ] && [ "$VM_CHOICE" -le "${#INSTANCES[@]}" ]; then
      INDEX=$((VM_CHOICE - 1))
      SELECTED_VM_NAME=$(echo "${INSTANCES[$INDEX]}" | awk '{print $1}')
      SELECTED_VM_ZONE=$(echo "${INSTANCES[$INDEX]}" | awk '{print $2}')
      SELECTED_VM_IP=$(echo "${INSTANCES[$INDEX]}" | awk '{print $3}')
      break
    else
      echo "Invalid selection. Please enter a number between 1 and ${#INSTANCES[@]}."
    fi
  done
fi

if [ -z "$SELECTED_VM_IP" ]; then
  echo "ERROR: The selected VM '$SELECTED_VM_NAME' does not have a public IP assigned." >&2
  exit 1
fi

# Extract GCP Region from Zone (e.g., us-central1-a -> us-central1)
REGION="${SELECTED_VM_ZONE%-*}"
ADDRESS_NAME="${SELECTED_VM_NAME}-static-ip"

echo ""
echo "----------------------------------------------------"
echo " Summary:"
echo " - Project:      $SELECTED_PROJECT"
echo " - Target VM:    $SELECTED_VM_NAME"
echo " - Zone/Region:  $SELECTED_VM_ZONE / $REGION"
echo " - Current IP:   $SELECTED_VM_IP"
echo " - IP Name:      $ADDRESS_NAME"
echo " - Network Tier: STANDARD (Free Tier Compatible)"
echo "----------------------------------------------------"

echo ""
echo "=== Promoting IP $SELECTED_VM_IP to Static External IP (STANDARD Tier) ==="

# Promote the ephemeral IP to static using the STANDARD network tier
gcloud compute addresses create "$ADDRESS_NAME" \
  --addresses="$SELECTED_VM_IP" \
  --region="$REGION" \
  --network-tier="STANDARD"

echo ""
echo "===================================================="
echo " Static IP reserved successfully!"
echo "===================================================="
echo " IP Address:  $SELECTED_VM_IP"
echo " Assigned to: $SELECTED_VM_NAME"
echo ""
echo " You can now point your domain's DNS A Record to: $SELECTED_VM_IP"
