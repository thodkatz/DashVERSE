#!/usr/bin/env bash
# Run on your LOCAL MACHINE (Manjaro / workstation).
# Opens SSH tunnels through the NixOS hypervisor into the VM so you can
# open DashVERSE in your local browser while everything runs in the VM.
#
# Usage:
#   NIXOS_HOST=myserver VM_IP=192.168.122.x ./tunnel.sh
#
# Required environment variables:
#   NIXOS_HOST   Hostname or IP of the NixOS hypervisor
#   VM_IP        IP of the VM inside the hypervisor (see: virsh net-dhcp-leases default)
#
# Optional:
#   VM_USER      VM username (default: dashverse)
#   NIXOS_USER   NixOS host username (default: current user)

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}==>${NC} $1"; }
error() { echo -e "${RED}Error:${NC} $1" >&2; exit 1; }

NIXOS_HOST="${NIXOS_HOST:-}"
VM_IP="${VM_IP:-}"
VM_USER="${VM_USER:-dashverse}"
NIXOS_USER="${NIXOS_USER:-$USER}"

usage() {
    echo "Usage: NIXOS_HOST=<server> VM_IP=<vm-ip> ./tunnel.sh"
    echo ""
    echo "  NIXOS_HOST   NixOS hypervisor hostname or IP (required)"
    echo "  VM_IP        VM IP inside the hypervisor (required)"
    echo "  VM_USER      VM username (default: dashverse)"
    echo "  NIXOS_USER   NixOS host username (default: $USER)"
    echo ""
    echo "Find the VM IP on the NixOS server:"
    echo "  sudo virsh net-dhcp-leases default"
    exit 1
}

[[ -z "$NIXOS_HOST" ]] && { echo -e "${RED}Error:${NC} NIXOS_HOST not set"; usage; }
[[ -z "$VM_IP" ]]      && { echo -e "${RED}Error:${NC} VM_IP not set";      usage; }

# Confirm make port-forward is running inside the VM
echo ""
log "Opening SSH tunnels"
echo ""
echo "  Jump host:   $NIXOS_USER@$NIXOS_HOST"
echo "  VM:          $VM_USER@$VM_IP"
echo ""
echo "  Superset:          http://localhost:8088"
echo "  Demo portal:       http://localhost:8080"
echo "  PostgREST API:     http://localhost:3000"
echo "  PostgREST docs:    http://localhost:3001"
echo "  Auth service:      http://localhost:8000"
echo "  Auth service docs: http://localhost:8001"
echo ""
echo -e "${YELLOW}Make sure 'make port-forward' is running inside the VM first.${NC}"
echo "Press Ctrl+C to close all tunnels."
echo ""

ssh \
    -J "$NIXOS_USER@$NIXOS_HOST" \
    -L 8088:localhost:8088 \
    -L 8080:localhost:8080 \
    -L 3000:localhost:3000 \
    -L 3001:localhost:3001 \
    -L 8000:localhost:8000 \
    -L 8001:localhost:8001 \
    -N \
    "$VM_USER@$VM_IP"
