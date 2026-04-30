#!/usr/bin/env bash
# Run INSIDE the VM (after create-vm.sh has booted it).
# Installs all tools needed to deploy DashVERSE:
#   Docker, kubectl, minikube, helm, opentofu, ansible, make, git, jq
#
# Usage (from the hypervisor host):
#   scp scripts/vm/setup-vm.sh dashverse@<VM_IP>:~/
#   ssh dashverse@<VM_IP> 'bash setup-vm.sh'

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "\n${GREEN}==>${NC} $1"; }
warn()  { echo -e "${YELLOW}  ->${NC} $1"; }
error() { echo -e "${RED}Error:${NC} $1" >&2; exit 1; }

# ── system update ────────────────────────────────────────────────────────────
log "Updating system packages"
sudo apt-get update -q
sudo apt-get upgrade -y -q

# ── Docker ───────────────────────────────────────────────────────────────────
log "Installing Docker"
sudo apt-get install -y docker.io
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"

# ── kubectl ──────────────────────────────────────────────────────────────────
log "Installing kubectl"
KUBECTL_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt)
curl -sSLo /tmp/kubectl \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm /tmp/kubectl

# ── minikube ─────────────────────────────────────────────────────────────────
log "Installing minikube"
curl -sSLo /tmp/minikube \
    https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install /tmp/minikube /usr/local/bin/minikube
rm /tmp/minikube

# ── helm ─────────────────────────────────────────────────────────────────────
log "Installing helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ── opentofu ─────────────────────────────────────────────────────────────────
log "Installing OpenTofu"
curl -fsSL https://get.opentofu.org/install-opentofu.sh \
    | sudo sh -s -- --install-method deb

# ── ansible + utilities ──────────────────────────────────────────────────────
log "Installing Ansible and utilities"
sudo apt-get install -y ansible make git python3 python3-pip jq curl wget

# ── verify ───────────────────────────────────────────────────────────────────
log "Verifying installations"
echo ""
printf "  %-18s %s\n" "docker:"   "$(docker --version)"
printf "  %-18s %s\n" "kubectl:"  "$(kubectl version --client --short 2>/dev/null || kubectl version --client)"
printf "  %-18s %s\n" "minikube:" "$(minikube version --short)"
printf "  %-18s %s\n" "helm:"     "$(helm version --short)"
printf "  %-18s %s\n" "opentofu:" "$(tofu --version | head -1)"
printf "  %-18s %s\n" "ansible:"  "$(ansible --version | head -1)"
echo ""

log "Setup complete!"
echo ""
warn "IMPORTANT: Docker group won't be active until you open a new shell."
echo ""
echo "Log out and back in, then run deploy-dashverse.sh:"
echo ""
echo "  exit"
echo "  ssh $USER@\$(hostname -I | awk '{print \$1}')"
echo "  git clone https://github.com/thodkatz/DashVERSE.git"
echo "  bash DashVERSE/scripts/vm/deploy-dashverse.sh"
echo ""
