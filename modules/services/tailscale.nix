{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.tailscale;
  authKeyFile = config.machine.secrets.paths.tailscale-authkey or null;
  autostart = config.machine.autostart.tailscaled or true;
in
{
  services.tailscale = {
    enable = lib.mkDefault true;
    # Only needed for the first login; the node identity then lives in /var/lib/tailscale.
    inherit authKeyFile;
    disableUpstreamLogging = true;
    openFirewall = true;
  };
  machine.secrets.use = [ "tailscale-authkey" ];
  machine.autostart.tailscaled = lib.mkIf cfg.enable (lib.mkDefault false);

  networking.firewall.trustedInterfaces = lib.mkIf cfg.enable [ cfg.interfaceName ];

  # Use nftables directly rather than the iptables-compat translation layer.
  systemd.services.tailscaled.serviceConfig.Environment = lib.mkIf cfg.enable [
    "TS_DEBUG_FIREWALL_MODE=nftables"
  ];

  # The login, which would start tailscaled, runs once tailscaled is started.
  # The mkIf is on the unit: one on wantedBy would leave an empty unit behind.
  systemd.services.tailscaled-autoconnect =
    lib.mkIf (cfg.enable && authKeyFile != null && !autostart)
      {
        wantedBy = lib.mkForce [ "tailscaled.service" ];
      };

  machine.healthchecks.checks = lib.mkIf cfg.enable {
    tailscaled = {
      type = "unit";
      target = "tailscaled.service";
    };
    # Logged in only once there is a key to log in with (`make secret
    # NAME=tailscale-authkey`); until then, failing would roll back every upgrade.
    tailscale-up = lib.mkIf (authKeyFile != null) {
      enable = autostart;
      type = "command";
      target = "${lib.getExe cfg.package} status --json | ${lib.getExe pkgs.jq} -e '.BackendState == \"Running\"'";
    };
  };
}
