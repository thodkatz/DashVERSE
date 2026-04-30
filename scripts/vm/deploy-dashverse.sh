#!/usr/bin/env bash
# Run INSIDE the VM after setup-vm.sh has completed.
# Clones DashVERSE, starts minikube, and deploys the full stack.
#
# Usage:
#   bash deploy-dashverse.sh
#
# Environment overrides:
#   REPO_URL         Git remote (default: GitHub EVERSE repo)
#   REPO_DIR         Local clone path (default: ~/DashVERSE)
#   MINIKUBE_CPUS    vCPUs for minikube (default: 4)
#   MINIKUBE_MEMORY  RAM for minikube (default: 6g)

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "\n${GREEN}==>${NC} $1"; }
warn()  { echo -e "${YELLOW}  ->${NC} $1"; }
error() { echo -e "${RED}Error:${NC} $1" >&2; exit 1; }

REPO_URL="${REPO_URL:-https://github.com/EVERSE-ResearchSoftware/DashVERSE.git}"
REPO_DIR="${REPO_DIR:-$HOME/DashVERSE}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-6g}"

# ── preflight checks ─────────────────────────────────────────────────────────
log "Checking prerequisites"

# Docker group membership (must be active, not just set)
if ! docker info &>/dev/null; then
    error "Cannot reach Docker daemon.
If you just ran setup-vm.sh, log out and back in so the docker group takes effect, then re-run this script."
fi

for cmd in kubectl minikube helm tofu ansible make git jq; do
    if ! command -v "$cmd" &>/dev/null; then
        error "$cmd not found — run setup-vm.sh first."
    fi
done
warn "All prerequisites present"

# ── clone / update repo ──────────────────────────────────────────────────────
if [[ -d "$REPO_DIR/.git" ]]; then
    log "Repo exists at $REPO_DIR — pulling latest"
    git -C "$REPO_DIR" pull --ff-only
else
    log "Cloning DashVERSE"
    git clone "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

# ── start minikube ───────────────────────────────────────────────────────────
if minikube status 2>/dev/null | grep -q "Running"; then
    warn "Minikube already running — skipping start"
else
    log "Starting minikube (driver=docker, cpus=$MINIKUBE_CPUS, memory=$MINIKUBE_MEMORY)"
    minikube start \
        --driver=docker \
        --cpus="$MINIKUBE_CPUS" \
        --memory="$MINIKUBE_MEMORY"
fi

log "Minikube status"
minikube status

# ── deploy ───────────────────────────────────────────────────────────────────
log "Deploying DashVERSE (make deploy ENV=local)"
warn "This builds Docker images and applies Terraform — may take several minutes"
make deploy ENV=local

# ── wait for pods ─────────────────────────────────────────────────────────────
log "Waiting for pods to become ready (up to 10 min)"

# Superset takes the longest — wait for it specifically
warn "Waiting for Superset pod (this can take 3–5 minutes on first run)..."
kubectl wait \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=superset \
    --namespace=dashverse \
    --timeout=600s

warn "Waiting for remaining pods..."
kubectl wait \
    --for=condition=ready pod \
    --selector=app=dashverse \
    --namespace=dashverse \
    --timeout=300s 2>/dev/null || true

log "Pod status"
make status

# ── seed data ────────────────────────────────────────────────────────────────
log "Seeding sample data (fetches from EVERSE TechRadar)"
make seed-data

# ── sync EVERSE indicators ───────────────────────────────────────────────────
log "Syncing EVERSE indicators"
make sync-apply

# ── configure Superset dashboards ────────────────────────────────────────────
# setup-dashboards uses Ansible to hit Superset at localhost:8088,
# so port-forward must be running while it executes.
log "Starting temporary port-forward for Superset dashboard setup"
./scripts/port-forward.sh &
PF_PID=$!

cleanup_pf() { kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; }
trap cleanup_pf EXIT

warn "Waiting 15 s for port-forward to establish..."
sleep 15

log "Configuring Superset dashboards via Ansible"
make setup-dashboards ENV=local

# stop temp port-forward (trap fires on EXIT but we stop it early so the
# final instructions are printed cleanly)
cleanup_pf
trap - EXIT

# ── done ─────────────────────────────────────────────────────────────────────
echo ""
log "Deployment complete!"
echo ""
echo "To access DashVERSE, start port-forwarding in a persistent session:"
echo ""
echo "  cd $REPO_DIR && make port-forward"
echo ""
echo "Services available at (on this VM's localhost):"
echo "  Superset:          http://localhost:8088"
echo "  Demo portal:       http://localhost:8080"
echo "  PostgREST API:     http://localhost:3000"
echo "  PostgREST docs:    http://localhost:3001"
echo "  Auth service:      http://localhost:8000"
echo "  Auth service docs: http://localhost:8001"
echo ""
echo "Credentials:"
./scripts/show-access.sh
echo ""
echo "To view from a remote machine, see scripts/vm/tunnel.sh"
echo ""
