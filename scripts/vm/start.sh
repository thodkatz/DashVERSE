#!/usr/bin/env bash
# Run on the NixOS server.
# Starts the DashVERSE VM, minikube, port-forward, and SSH tunnels.
#
# Usage:
#   bash scripts/vm/start.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}==>${NC} $1"; }
warn()  { echo -e "${YELLOW}  ->${NC} $1"; }
error() { echo -e "${RED}Error:${NC} $1" >&2; exit 1; }

VM_NAME="${VM_NAME:-dashverse-test}"
VM_USER="${VM_USER:-dashverse}"
DNSMASQ_LEASES="/var/lib/dnsmasq/dnsmasq.leases"

# ── detect Tailscale IP ──────────────────────────────────────────────────────
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null \
    || ip addr show tailscale0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 \
    || true)

[[ -z "$TAILSCALE_IP" ]] && error "Could not detect Tailscale IP. Is tailscale running?"

# ── step 1: start VM ─────────────────────────────────────────────────────────
log "Checking VM state"
VM_STATE=$(virsh -c qemu:///system domstate "$VM_NAME" 2>/dev/null || echo "not found")

if [[ "$VM_STATE" == "running" ]]; then
    warn "VM already running"
elif [[ "$VM_STATE" == "shut off" ]]; then
    log "Starting VM: $VM_NAME"
    virsh -c qemu:///system start "$VM_NAME"
else
    error "VM '$VM_NAME' not found. Run scripts/vm/create-vm.sh first."
fi

# ── step 2: wait for SSH ─────────────────────────────────────────────────────
log "Waiting for VM SSH (up to 60 s)..."
VM_IP=""
for i in $(seq 1 12); do
    VM_IP=$(awk "/$VM_NAME/ {print \$3}" "$DNSMASQ_LEASES" 2>/dev/null | head -1)
    if [[ -n "$VM_IP" ]]; then
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -o BatchMode=yes "$VM_USER@$VM_IP" true 2>/dev/null && break
    fi
    echo "  [$((i * 5))s] waiting..."
    sleep 5
done

[[ -z "$VM_IP" ]] && error "Could not reach VM. Check: cat $DNSMASQ_LEASES"
log "VM reachable at $VM_IP"

# ── step 3: start minikube ───────────────────────────────────────────────────
log "Starting minikube"
MINIKUBE_STATE=$(ssh -o StrictHostKeyChecking=no "$VM_USER@$VM_IP" \
    'minikube status 2>/dev/null | grep -i "host:" | awk "{print \$2}"' || true)

if [[ "$MINIKUBE_STATE" == "Running" ]]; then
    warn "Minikube already running"
else
    ssh -o StrictHostKeyChecking=no "$VM_USER@$VM_IP" \
        'minikube start --driver=docker'
fi

# ── step 4: start port-forward in VM ────────────────────────────────────────
log "Starting port-forward inside VM"
PF_RUNNING=$(ssh -o StrictHostKeyChecking=no "$VM_USER@$VM_IP" \
    'pgrep -f port-forward.sh > /dev/null 2>&1 && echo yes || echo no')

if [[ "$PF_RUNNING" == "yes" ]]; then
    warn "Port-forward already running"
else
    ssh -o StrictHostKeyChecking=no "$VM_USER@$VM_IP" \
        'cd ~/DashVERSE && nohup make port-forward > ~/pf.log 2>&1 &'
    sleep 3
fi

# ── step 5: SSH tunnels on NixOS server ─────────────────────────────────────
log "Opening SSH tunnels on $TAILSCALE_IP"

# kill any stale tunnels to the VM first
pkill -f "ssh.*$VM_IP" 2>/dev/null || true
sleep 1

ssh -o StrictHostKeyChecking=no -f -N \
    -L "$TAILSCALE_IP:8088:localhost:8088" \
    -L "$TAILSCALE_IP:8083:localhost:8083" \
    -L "$TAILSCALE_IP:3000:localhost:3000" \
    -L "$TAILSCALE_IP:3001:localhost:3001" \
    -L "$TAILSCALE_IP:8000:localhost:8000" \
    -L "$TAILSCALE_IP:8001:localhost:8001" \
    "$VM_USER@$VM_IP"

echo ""
log "DashVERSE is up!"
echo ""
echo "  Superset:          http://$TAILSCALE_IP:8088"
echo "  Demo portal:       http://$TAILSCALE_IP:8083"
echo "  PostgREST API:     http://$TAILSCALE_IP:3000"
echo "  PostgREST docs:    http://$TAILSCALE_IP:3001"
echo "  Auth service:      http://$TAILSCALE_IP:8000"
echo "  Auth service docs: http://$TAILSCALE_IP:8001"
echo ""
echo "Credentials:"
ssh -o StrictHostKeyChecking=no "$VM_USER@$VM_IP" \
    'cd ~/DashVERSE && ./scripts/show-access.sh'
echo ""
