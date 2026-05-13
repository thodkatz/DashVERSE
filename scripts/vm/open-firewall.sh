#!/usr/bin/env bash
# Allow DashVERSE ports through ufw on the host machine.
# Run on the host machine before accessing services via IP.
#
# Usage:
#   bash scripts/vm/open-firewall.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} $1"; }
warn() { echo -e "${YELLOW}  ->${NC} $1"; }
error() { echo -e "${RED}Error:${NC} $1" >&2; exit 1; }

PORTS=(8088 8083 3000 3001 8000 8001)

if ! command -v ufw &>/dev/null; then
    error "ufw not found. On NixOS use networking.firewall.trustedInterfaces instead."
fi

if ! sudo ufw status 2>/dev/null | grep -q "^Status: active"; then
    warn "ufw is not active — no rules applied"
    exit 0
fi

log "Allowing DashVERSE ports through ufw"
for port in "${PORTS[@]}"; do
    sudo ufw allow "$port"/tcp \
        && warn "allowed $port/tcp" \
        || warn "skipped $port (already allowed or insufficient permissions)"
done

echo ""
log "Done. Current ufw rules for DashVERSE ports:"
for port in "${PORTS[@]}"; do
    sudo ufw status | grep "$port" || true
done
echo ""
