#!/usr/bin/env bash
# Run on the NixOS server.
# Stops SSH tunnels, port-forward, minikube, and optionally the VM.
#
# Usage:
#   bash scripts/vm/stop.sh            # stop tunnels + port-forward + minikube
#   bash scripts/vm/stop.sh --vm       # also shut down the VM

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} $1"; }
warn() { echo -e "${YELLOW}  ->${NC} $1"; }

VM_NAME="${VM_NAME:-dashverse-test}"
VM_USER="${VM_USER:-dashverse}"
SHUTDOWN_VM=false
DNSMASQ_LEASES="/var/lib/dnsmasq/dnsmasq.leases"

[[ "${1:-}" == "--vm" ]] && SHUTDOWN_VM=true

# ── step 1: kill SSH tunnels on NixOS server ─────────────────────────────────
log "Stopping SSH tunnels"
VM_IP=$(awk "/$VM_NAME/ {print \$3}" "$DNSMASQ_LEASES" 2>/dev/null | head -1)

if [[ -n "$VM_IP" ]]; then
    pkill -f "ssh.*$VM_IP" 2>/dev/null && warn "Tunnels stopped" || warn "No tunnels were running"
else
    warn "VM IP not found — skipping tunnel cleanup"
fi

# ── step 2: stop port-forward inside VM ─────────────────────────────────────
log "Stopping port-forward inside VM"
if [[ -n "$VM_IP" ]]; then
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        "$VM_USER@$VM_IP" \
        'pkill -f port-forward.sh 2>/dev/null; pkill -f "kubectl port-forward" 2>/dev/null; echo done' \
        2>/dev/null && warn "Port-forward stopped" || warn "VM unreachable — skipping"
fi

# ── step 3: stop minikube ────────────────────────────────────────────────────
log "Stopping minikube"
if [[ -n "$VM_IP" ]]; then
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        "$VM_USER@$VM_IP" \
        'minikube stop' \
        2>/dev/null && warn "Minikube stopped" || warn "VM unreachable — skipping"
fi

# ── step 4: shutdown VM (optional) ──────────────────────────────────────────
if $SHUTDOWN_VM; then
    log "Shutting down VM: $VM_NAME"
    virsh -c qemu:///system shutdown "$VM_NAME" 2>/dev/null \
        && warn "VM shutdown initiated" \
        || warn "VM was not running"
else
    warn "VM left running (use --vm flag to shut it down)"
fi

echo ""
log "Done."
echo ""
echo "To start again: bash scripts/vm/start.sh"
echo ""
