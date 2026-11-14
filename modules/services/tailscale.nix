# Tailscale, logged in by hand once the machine is running (`sudo tailscale
# up`): the node identity then lives in /var/lib/tailscale. No auth key is kept,
# so whether it is logged in isn't healthchecked, only that tailscaled runs.
{ config, lib, ... }:

let
  cfg = config.services.tailscale;
in
{
  services.tailscale = {
    enable = lib.mkDefault true;
    disableUpstreamLogging = true;
    openFirewall = true;
  };
  machine.autostart.tailscaled = lib.mkIf cfg.enable (lib.mkDefault false);

  networking.firewall.trustedInterfaces = lib.mkIf cfg.enable [ cfg.interfaceName ];

  # Use nftables directly rather than the iptables-compat translation layer.
  systemd.services.tailscaled.serviceConfig.Environment = lib.mkIf cfg.enable [
    "TS_DEBUG_FIREWALL_MODE=nftables"
  ];

  machine.healthchecks.checks.tailscaled = lib.mkIf cfg.enable {
    type = "unit";
    target = "tailscaled.service";
  };
}
