# Notifications through ntfy, once its secret exists (`make secret NAME=ntfy`:
# NTFY_URL=https://ntfy.sh and NTFY_TOPIC=<topic> lines). A unit with
#   onFailure = config.machine.notify.onFailure;
# sends its status when it fails; Gatus sends its alerts with the same secret.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.machine.notify;

  notifyFailure = pkgs.writeShellApplication {
    name = "notify-failure";
    runtimeInputs = [
      pkgs.curl
      config.systemd.package
    ];
    text = ''
      unit=$1
      systemctl status --no-pager --lines=10 "$unit" |
        curl --silent --show-error --max-time 10 \
          --header "Title: ${config.networking.hostName}: $unit failed" \
          --header "Tags: warning" \
          --data-binary @- "$NTFY_URL/$NTFY_TOPIC"
    '';
  };
in
{
  options.machine.notify = {
    environmentFile = lib.mkOption {
      type = with lib.types; nullOr str;
      readOnly = true;
      default = config.machine.secrets.paths.ntfy or null;
      description = "NTFY_URL and NTFY_TOPIC, once the ntfy secret exists.";
    };
    onFailure = lib.mkOption {
      type = with lib.types; listOf str;
      readOnly = true;
      default = lib.optional (cfg.environmentFile != null) "notify-failure@%n.service";
      description = "A unit's onFailure that sends a notification, once the ntfy secret exists.";
    };
  };

  config = {
    machine.secrets.use = [ "ntfy" ];

    systemd.services."notify-failure@" = lib.mkIf (cfg.environmentFile != null) {
      description = "Notify that %i failed";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = cfg.environmentFile;
        ExecStart = "${lib.getExe notifyFailure} %i";
      };
    };
  };
}
