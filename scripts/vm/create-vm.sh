#!/usr/bin/env bash
# Run on the NixOS (or any Linux) hypervisor host.
# Creates an Ubuntu 24.04 VM suitable for running DashVERSE.
#
# Networking: uses a NixOS-managed virbr0 bridge (defined in configuration.nix)
# rather than libvirt's own network, which avoids permission issues on NixOS.
#
# Prerequisites on the host:
#   virtualisation.libvirtd.enable = true   (NixOS) — see docs/VM.md
#   networking.bridges.virbr0 configured    (NixOS) — see docs/VM.md
#   packages: virt-install, qemu-img, cloud-localds (cloud-utils)
#
# Usage:
#   ./create-vm.sh
#
# Environment overrides:
#   VM_NAME        VM name (default: dashverse-test)
#   VM_CPUS        vCPU count (default: 4)
#   VM_MEMORY      RAM in MB (default: 8192)
#   VM_DISK_SIZE   Disk in GB (default: 40)
#   VM_USER        Guest username (default: dashverse)
#   IMAGE_DIR      Libvirt image directory (default: /var/lib/libvirt/images)

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}==>${NC} $1"; }
warn()  { echo -e "${YELLOW}==>${NC} $1"; }
error() { echo -e "${RED}Error:${NC} $1" >&2; exit 1; }

VM_NAME="${VM_NAME:-dashverse-test}"
VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY="${VM_MEMORY:-8192}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40}"
VM_USER="${VM_USER:-dashverse}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
BRIDGE="${BRIDGE:-virbr0}"

CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
CLOUD_IMAGE_FILE="noble-server-cloudimg-amd64.img"

DNSMASQ_LEASES="/var/lib/dnsmasq/dnsmasq.leases"

# ── dependency check ────────────────────────────────────────────────────────
for cmd in virt-install virsh qemu-img cloud-localds; do
    if ! command -v "$cmd" &>/dev/null; then
        error "$cmd not found. See docs/VM.md — NixOS Setup section."
    fi
done

# ── bridge must exist (NixOS manages it) ────────────────────────────────────
if ! ip link show "$BRIDGE" &>/dev/null; then
    error "Bridge $BRIDGE does not exist.
Run 'sudo nixos-rebuild switch' with the bridge config from docs/VM.md, then retry."
fi

# ── SSH key ─────────────────────────────────────────────────────────────────
SSH_KEY=""
for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
    if [[ -f "$key_file" ]]; then
        SSH_KEY=$(cat "$key_file")
        log "Using SSH key: $key_file"
        break
    fi
done
[[ -z "$SSH_KEY" ]] && error "No SSH public key found. Run: ssh-keygen -t ed25519"

# ── guard: VM must not already exist ────────────────────────────────────────
if virsh dominfo "$VM_NAME" &>/dev/null; then
    error "VM '$VM_NAME' already exists. Remove it first:
  virsh destroy $VM_NAME 2>/dev/null || true
  sudo virsh undefine $VM_NAME --remove-all-storage"
fi

echo ""
log "Creating VM: $VM_NAME"
echo "  CPUs:   $VM_CPUS"
echo "  Memory: ${VM_MEMORY} MB"
echo "  Disk:   ${VM_DISK_SIZE} GB"
echo "  User:   $VM_USER"
echo "  Bridge: $BRIDGE"
echo ""

# ── ensure image directory exists ───────────────────────────────────────────
if [[ ! -d "$IMAGE_DIR" ]]; then
    log "Creating image directory: $IMAGE_DIR"
    sudo mkdir -p "$IMAGE_DIR"
fi

# ── define default storage pool if missing ──────────────────────────────────
if ! virsh pool-info default &>/dev/null; then
    log "Defining libvirt default storage pool"
    virsh pool-define-as default dir - - - - "$IMAGE_DIR"
    virsh pool-build default
    virsh pool-start default
    virsh pool-autostart default
fi

# ── download cloud image (once) ─────────────────────────────────────────────
BASE_IMAGE="$IMAGE_DIR/$CLOUD_IMAGE_FILE"
if [[ ! -f "$BASE_IMAGE" ]]; then
    log "Downloading Ubuntu 24.04 cloud image..."
    sudo wget -O "$BASE_IMAGE" "$CLOUD_IMAGE_URL"
else
    log "Cloud image already present: $BASE_IMAGE"
fi

# ── create layered disk from base image ─────────────────────────────────────
VM_DISK="$IMAGE_DIR/${VM_NAME}.qcow2"
log "Creating VM disk (${VM_DISK_SIZE} GB) from base image..."
sudo qemu-img create -F qcow2 -b "$BASE_IMAGE" -f qcow2 "$VM_DISK" "${VM_DISK_SIZE}G"

# ── cloud-init seed ISO ──────────────────────────────────────────────────────
CLOUD_TMPDIR=$(mktemp -d)
trap 'rm -rf "$CLOUD_TMPDIR"' EXIT

cat > "$CLOUD_TMPDIR/user-data" << EOF
#cloud-config
hostname: $VM_NAME

users:
  - name: $VM_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: [docker, sudo]
    ssh_authorized_keys:
      - $SSH_KEY

package_update: true
packages:
  - qemu-guest-agent

runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

cat > "$CLOUD_TMPDIR/meta-data" << EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

SEED_ISO="$IMAGE_DIR/${VM_NAME}-seed.iso"
log "Building cloud-init seed ISO..."
sudo cloud-localds "$SEED_ISO" "$CLOUD_TMPDIR/user-data" "$CLOUD_TMPDIR/meta-data"

# ── create and boot VM ───────────────────────────────────────────────────────
log "Creating and booting VM..."
sudo virt-install \
    --name "$VM_NAME" \
    --vcpus "$VM_CPUS" \
    --memory "$VM_MEMORY" \
    --disk "$VM_DISK,format=qcow2" \
    --disk "$SEED_ISO,device=cdrom" \
    --os-variant ubuntu24.04 \
    --network bridge="$BRIDGE" \
    --import \
    --noautoconsole \
    --graphics none

# ── wait for DHCP lease ──────────────────────────────────────────────────────
log "Waiting for VM to acquire DHCP lease (up to 90 s)..."
VM_IP=""
for i in $(seq 1 18); do
    # Try dnsmasq leases file first, fall back to ARP table
    if [[ -f "$DNSMASQ_LEASES" ]]; then
        VM_IP=$(awk "/$VM_NAME/ {print \$3}" "$DNSMASQ_LEASES" | head -1)
    fi
    if [[ -z "$VM_IP" ]]; then
        VM_IP=$(arp -an 2>/dev/null | grep "192\.168\.122\." | awk '{print $2}' | tr -d '()' | head -1)
    fi
    [[ -n "$VM_IP" ]] && break
    echo "  [$((i * 5))s] waiting..."
    sleep 5
done

echo ""
if [[ -z "$VM_IP" ]]; then
    warn "VM IP not found yet — cloud-init may still be booting."
    echo "Check the leases file once the VM boots:"
    echo "  cat $DNSMASQ_LEASES"
    echo "  # or: arp -an | grep 192.168.122"
    echo ""
    echo "Once you have the IP, proceed with:"
    echo "  scp scripts/vm/setup-vm.sh $VM_USER@<VM_IP>:~/"
    echo "  ssh $VM_USER@<VM_IP> 'bash setup-vm.sh'"
else
    log "VM is up at: $VM_IP"
    echo ""
    echo "Wait ~30 s for cloud-init to finish, then:"
    echo ""
    echo "  scp scripts/vm/setup-vm.sh $VM_USER@$VM_IP:~/"
    echo "  ssh $VM_USER@$VM_IP 'bash setup-vm.sh'"
fi
echo ""
