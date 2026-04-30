# NixOS configuration snippet — add to /etc/nixos/configuration.nix
# Enables KVM/libvirt so you can run VMs on a headless NixOS server.
#
# After editing, apply with:
#   sudo nixos-rebuild switch
#
# Then log out and back in so the new group memberships (libvirtd, kvm) take effect.
#
# Notes on NixOS-specific behaviour:
#   - The correct nixpkgs attribute is `virt-manager` (not `virt-install`); it provides the virt-install CLI.
#   - `cloud-utils` (not `cloud-image-utils`) provides cloud-localds.
#   - libvirt on NixOS cannot create the virbr0 bridge at runtime due to capability restrictions,
#     so the bridge, NAT, and DHCP must be declared here and managed by NixOS.

{
  # ── KVM / libvirt ──────────────────────────────────────────────────────────
  virtualisation.libvirtd.enable = true;
  virtualisation.libvirtd.allowedBridges = [ "virbr0" ];

  # ── host tools ────────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    virt-manager  # provides virt-install CLI
    cloud-utils   # provides cloud-localds
    qemu-utils    # provides qemu-img
  ];

  # ── allow your user to manage VMs ────────────────────────────────────────
  # Replace <youruser> with your actual NixOS username.
  users.users.<youruser>.extraGroups = [ "libvirtd" "kvm" ];

  # ── NixOS-managed bridge (libvirt attaches VMs, does not own it) ─────────
  networking.bridges.virbr0.interfaces = [];
  networking.interfaces.virbr0.ipv4.addresses = [{
    address = "192.168.122.1";
    prefixLength = 24;
  }];

  # Keep NetworkManager away from libvirt interfaces
  networking.networkmanager.unmanaged = [ "interface-name:virbr0" "interface-name:vnet*" ];

  # IP forwarding so VMs can reach the internet through the host
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # NAT outbound traffic from VMs
  networking.nat = {
    enable = true;
    internalInterfaces = [ "virbr0" ];
  };

  # DHCP server for VMs on the bridge
  services.dnsmasq = {
    enable = true;
    settings = {
      interface = "virbr0";
      bind-interfaces = true;
      dhcp-range = "192.168.122.2,192.168.122.254,24h";
    };
  };

  # Allow bridge traffic through the firewall
  networking.firewall.trustedInterfaces = [ "virbr0" ];
}
