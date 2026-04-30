# Testing DashVERSE in a VM

End-to-end guide for spinning up a headless Ubuntu 24.04 VM on a NixOS server
and deploying the full DashVERSE stack (Terraform + Kubernetes + Ansible) inside it.

## Overview

```
Manjaro workstation  ──SSH tunnel──►  NixOS server  ──NAT──►  Ubuntu VM
  browser:8088                         (hypervisor)              (DashVERSE)
```

The VM runs Minikube (docker driver), OpenTofu, and Ansible.
Everything is accessed from the workstation browser via an SSH jump tunnel.

---

## Phase 1 — NixOS: enable the hypervisor

Add the snippet in [scripts/vm/nixos-hypervisor.nix](../scripts/vm/nixos-hypervisor.nix)
to your `/etc/nixos/configuration.nix`, replacing `<youruser>` with your username:

```nix
virtualisation.libvirtd.enable = true;
virtualisation.libvirtd.allowedBridges = [ "virbr0" ];
users.users.<youruser>.extraGroups = [ "libvirtd" "kvm" ];
environment.systemPackages = with pkgs; [
  virt-install
  cloud-image-utils
  qemu-utils
];
networking.firewall.trustedInterfaces = [ "virbr0" ];
```

Apply and re-login:

```sh
sudo nixos-rebuild switch
# log out and back in so group membership takes effect
```

---

## Phase 2 — Create the VM

Run [scripts/vm/create-vm.sh](../scripts/vm/create-vm.sh) on the **NixOS server**.
It downloads the Ubuntu 24.04 cloud image, injects your SSH public key via
cloud-init, and boots the VM with `virt-install`.

```sh
# from the DashVERSE repo root on the NixOS server:
bash scripts/vm/create-vm.sh
```

**Environment overrides** (all optional):

| Variable | Default | Description |
|---|---|---|
| `VM_NAME` | `dashverse-test` | libvirt VM name |
| `VM_CPUS` | `4` | vCPU count |
| `VM_MEMORY` | `8192` | RAM in MB |
| `VM_DISK_SIZE` | `40` | Disk in GB |
| `VM_USER` | `dashverse` | Guest OS username |
| `IMAGE_DIR` | `/var/lib/libvirt/images` | Image storage path |

The script prints the VM IP when the DHCP lease appears. If it times out, check:

```sh
sudo virsh net-dhcp-leases default
```

Cloud-init runs on first boot and may take ~30 seconds after the lease appears.
Wait until SSH is reachable before proceeding:

```sh
ssh dashverse@<VM_IP>   # should succeed before moving on
```

### VM lifecycle commands

```sh
# list all VMs
sudo virsh list --all

# start / stop / delete
sudo virsh start dashverse-test
sudo virsh shutdown dashverse-test
sudo virsh destroy dashverse-test        # force off
sudo virsh undefine dashverse-test --remove-all-storage
```

---

## Phase 3 — Install dependencies inside the VM

Copy and run [scripts/vm/setup-vm.sh](../scripts/vm/setup-vm.sh) **inside the VM**.

```sh
# from the hypervisor host (or Manjaro via jump):
scp scripts/vm/setup-vm.sh dashverse@<VM_IP>:~/
ssh dashverse@<VM_IP> 'bash setup-vm.sh'
```

This installs:

| Tool | Purpose |
|---|---|
| Docker | Minikube container driver + image builds |
| kubectl | Kubernetes CLI |
| minikube | Local Kubernetes cluster |
| helm | Kubernetes package manager |
| OpenTofu | Infrastructure-as-code (Terraform-compatible) |
| Ansible | Superset dashboard configuration |
| make, git, jq | Build tooling |

After the script finishes, **log out and back in** so the Docker group takes effect:

```sh
exit
ssh dashverse@<VM_IP>
```

---

## Phase 4 — Deploy DashVERSE

Clone the repo inside the VM and run [scripts/vm/deploy-dashverse.sh](../scripts/vm/deploy-dashverse.sh):

```sh
# inside the VM:
git clone https://github.com/EVERSE-ResearchSoftware/DashVERSE.git
bash DashVERSE/scripts/vm/deploy-dashverse.sh
```

The script runs these steps in order:

| Step | Makefile target | Notes |
|---|---|---|
| Start Minikube | — | `--driver=docker`, 4 CPUs, 6 GB RAM |
| Build images | `build-auth`, `build-demo` | Builds directly into Minikube |
| Deploy infrastructure | `make deploy ENV=local` | `tofu init` + `tofu apply` |
| Wait for pods | — | Waits up to 10 min; Superset is slowest |
| Seed sample data | `make seed-data` | Fetches from EVERSE TechRadar |
| Sync indicators | `make sync-apply` | Downloads and imports EVERSE data |
| Configure dashboards | `make setup-dashboards ENV=local` | Ansible + temporary port-forward |

**Expected duration:** 15–30 minutes on first run (image pulls + Superset init).

### Manual step-by-step (if you prefer not to use the script)

```sh
cd DashVERSE

# 1. start cluster
minikube start --driver=docker --cpus=4 --memory=6g

# 2. deploy
make deploy ENV=local

# 3. check pods
make status
# wait until all pods show Running/Completed

# 4. seed data
make seed-data

# 5. sync EVERSE indicators
make sync-apply

# 6. configure Superset (needs port-forward running in another terminal)
make port-forward &
sleep 15
make setup-dashboards ENV=local
kill %1
```

---

## Phase 5 — Access DashVERSE

### Start port-forwarding (in the VM)

Keep this running in a terminal inside the VM:

```sh
cd DashVERSE && make port-forward
```

Services are now available on the VM's `localhost`:

| Service | URL |
|---|---|
| Superset (dashboards) | http://localhost:8088 |
| Demo portal | http://localhost:8080 |
| PostgREST API | http://localhost:3000 |
| PostgREST API docs | http://localhost:3001 |
| Auth service | http://localhost:8000 |
| Auth service docs | http://localhost:8001 |

### Open tunnels from Manjaro (workstation)

Run [scripts/vm/tunnel.sh](../scripts/vm/tunnel.sh) on your **local machine**:

```sh
NIXOS_HOST=<nixos-server> VM_IP=<vm-ip> bash scripts/vm/tunnel.sh
```

Then open http://localhost:8088 in your local browser.

To get the VM IP from the NixOS server:

```sh
sudo virsh net-dhcp-leases default
```

### Retrieve credentials

Credentials are auto-generated during deployment and stored in Kubernetes secrets:

```sh
# inside the VM:
./scripts/show-access.sh
```

Or individually:

```sh
kubectl get secret dashverse-secrets -n dashverse \
  -o jsonpath='{.data.superset-admin-password}' | base64 -d
```

Default Superset login: `admin` / *(password from secret)*

---

## Troubleshooting

### Pod stuck in `ImagePullBackOff`

The image was not built into Minikube's registry. Rebuild:

```sh
make build-auth build-demo
kubectl rollout restart deployment -n dashverse
```

### Superset pod `CrashLoopBackOff`

Usually a first-boot init race. Wait a few minutes and check:

```sh
make logs-superset
```

### Port-forward drops

`make port-forward` auto-restarts each tunnel on failure (see
[scripts/port-forward.sh](../scripts/port-forward.sh)).
If a service is unreachable, check the pod is still running:

```sh
make status
```

### Find VM IP after reboot

```sh
# on the NixOS server:
sudo virsh net-dhcp-leases default
```

### Tear down everything

```sh
# inside the VM — remove Kubernetes resources:
make destroy

# then delete the cluster:
minikube stop
minikube delete

# on the NixOS server — delete the VM entirely:
sudo virsh destroy dashverse-test
sudo virsh undefine dashverse-test --remove-all-storage
```

---

## Scripts reference

| Script | Where to run | Purpose |
|---|---|---|
| [scripts/vm/nixos-hypervisor.nix](../scripts/vm/nixos-hypervisor.nix) | NixOS `/etc/nixos/` | Enable KVM + libvirt |
| [scripts/vm/create-vm.sh](../scripts/vm/create-vm.sh) | NixOS server | Create and boot the Ubuntu VM |
| [scripts/vm/setup-vm.sh](../scripts/vm/setup-vm.sh) | Inside the VM | Install all dependencies |
| [scripts/vm/deploy-dashverse.sh](../scripts/vm/deploy-dashverse.sh) | Inside the VM | Clone repo + full deploy |
| [scripts/vm/tunnel.sh](../scripts/vm/tunnel.sh) | Local workstation | SSH tunnels to the VM |
