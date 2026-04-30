# NixOS configuration snippet — add to /etc/nixos/configuration.nix
# Enables KVM/libvirt so you can run VMs on a headless NixOS server.
#
# After editing, apply with:
#   sudo nixos-rebuild switch
#
# Then log out and back in so the new group membership (libvirtd, kvm) takes effect.

{
  # ── KVM / libvirt ──────────────────────────────────────────────────────────
  virtualisation.libvirtd.enable = true;
  virtualisation.libvirtd.allowedBridges = [ "virbr0" ];

  # ── tools available on the host ───────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    virt-manager       # CLI VM creation
    cloud-utils        # cloud-localds (builds cloud-init seed ISOs)
    qemu-utils         # qemu-img
    virtiofsd          # optional: virtio-fs host daemon
  ];

  # ── allow your user to manage VMs without sudo ────────────────────────────
  # Replace <youruser> with your actual NixOS username.
  users.users.<youruser>.extraGroups = [ "libvirtd" "kvm" ];

  # ── let libvirt bridge traffic through the firewall ───────────────────────
  networking.firewall.trustedInterfaces = [ "virbr0" ];
}
