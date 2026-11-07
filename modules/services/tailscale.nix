{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.tailscale;
in
{
  services.tailscale = {
    enable = lib.mkDefault true;
    # Only needed for the first login; the node identity then lives in /var/lib/tailscale.
    authKeyFile = config.machine.secrets.paths.tailscale-authkey or null;
    disableUpstreamLogging = true;
    openFirewall = true;
  };
  machine.secrets.use = [ "tailscale-authkey" ];

  networking.firewall.trustedInterfaces = lib.mkIf cfg.enable [ cfg.interfaceName ];

  # Use nftables directly rather than the iptables-compat translation layer.
  systemd.services.tailscaled.serviceConfig.Environment = lib.mkIf cfg.enable [
    "TS_DEBUG_FIREWALL_MODE=nftables"
  ];

  machine.healthchecks.checks = lib.mkIf cfg.enable {
    tailscaled = {
      type = "unit";
      target = "tailscaled.service";
    };
    tailscale-up = {
      type = "command";
      target = "${lib.getExe cfg.package} status --json | ${lib.getExe pkgs.jq} -e '.BackendState == \"Running\"'";
    };
  };
}
