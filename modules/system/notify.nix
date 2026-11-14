# Notifications through ntfy, once an admin has put NTFY_URL=https://ntfy.sh
# and NTFY_TOPIC=<topic> lines in /etc/credstore/ntfy on the machine; until
# then nothing is sent. A unit with
#   onFailure = config.machine.notify.onFailure;
# sends its status when it fails; Gatus sends its alerts with the same file.
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
      if [ -z "''${NTFY_URL:-}" ] || [ -z "''${NTFY_TOPIC:-}" ]; then
        echo "not notifying that $unit failed: no ntfy topic in ${cfg.environmentFile}"
        exit 0
      fi
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
      type = lib.types.str;
      readOnly = true;
      default = "/etc/credstore/ntfy";
      description = "NTFY_URL and NTFY_TOPIC, on the machine, once an admin has put them there.";
    };
    onFailure = lib.mkOption {
      type = with lib.types; listOf str;
      readOnly = true;
      default = [ "notify-failure@%n.service" ];
      description = "A unit's onFailure that sends a notification, once ntfy's environmentFile exists.";
    };
  };

  config = {
    systemd.services."notify-failure@" = {
      description = "Notify that %i failed";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "-${cfg.environmentFile}";
        ExecStart = "${lib.getExe notifyFailure} %i";
      };
    };
  };
}
