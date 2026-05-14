#!/usr/bin/env bash
# Run INSIDE the VM.
# Installs a systemd user service that keeps kubectl port-forward running
# persistently, surviving logout and reboots.
#
# Usage:
#   bash scripts/vm/install-port-forward-service.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} $1"; }
warn() { echo -e "${YELLOW}  ->${NC} $1"; }

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SERVICE_NAME="dashverse-port-forward"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/$SERVICE_NAME.service"

log "Creating systemd user service"
mkdir -p "$SERVICE_DIR"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=DashVERSE kubectl port-forward
After=default.target

[Service]
ExecStart=$REPO_DIR/scripts/port-forward.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

log "Enabling linger for $USER (service survives logout)"
loginctl enable-linger "$USER"

log "Enabling and starting $SERVICE_NAME"
systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME"

echo ""
log "Done!"
echo ""
echo "  Status:  systemctl --user status $SERVICE_NAME"
echo "  Logs:    journalctl --user -u $SERVICE_NAME -f"
echo "  Stop:    systemctl --user stop $SERVICE_NAME"
echo "  Disable: systemctl --user disable $SERVICE_NAME"
echo ""
