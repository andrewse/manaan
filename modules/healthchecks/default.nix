# Healthchecks declared by each module, e.g.
#   machine.healthchecks.checks.ssh-port = { type = "tcp"; target = "127.0.0.1:22"; };
# They run as healthcheck.service on every boot (gating self-upgrade), as the
# `healthcheck` command, and inside the VM test in CI. Services with a health
# endpoint declare it in machine.healthchecks.services (services.nix) instead.
# Always on, whether or not machine.monitoring.enable is: upgrades depend on them.
{
  config,
  lib,
  pkgs,
  machineLib,
  ...
}:

let
  cfg = config.machine.healthchecks;
  enabled = lib.filterAttrs (_: check: check.enable) cfg.checks;

  script = machineLib.mkScript {
    name = "healthcheck";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.curl
      pkgs.gnused
      config.systemd.package
    ];
    parts = [
      ./healthcheck.sh
      (lib.concatStrings (
        lib.mapAttrsToList (
          name: check:
          "check ${
            lib.escapeShellArgs [
              name
              check.type
              check.target
              (toString check.timeout)
            ]
          }\n"
        ) enabled
      ))
      ''
        report
      ''
    ];
  };
in
{
  imports = [ ./services.nix ];

  options.machine.healthchecks = {
    checks = lib.mkOption {
      default = { };
      description = "Checks that must pass for the machine to count as healthy.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            type = lib.mkOption {
              type = lib.types.enum [
                "tcp"
                "http"
                "unit"
                "command"
              ];
              description = ''
                tcp: target is host:port and must accept a connection.
                http: target is a URL and must answer with a 2xx/3xx status.
                unit: target is a systemd unit and must be active. While it is
                  activating (starting) it is waited for; once failed
                  (unhealthy) it fails at once. See machine.healthchecks.services.
                command: target is a shell command and must exit 0.
              '';
            };
            target = lib.mkOption { type = lib.types.str; };
            timeout = lib.mkOption {
              type = lib.types.ints.unsigned;
              default = cfg.timeout;
              defaultText = lib.literalExpression "config.machine.healthchecks.timeout";
              description = "Seconds after the healthchecks start to keep waiting for this check.";
            };
          };
        }
      );
    };
    timeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Seconds to keep retrying a failing check after boot before giving up, unless the check sets its own.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = script;
    };
  };

  config = {
    environment.systemPackages = [ script ];

    systemd.services.healthcheck = {
      description = "Healthchecks";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      inherit (config.machine.notify) onFailure;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe script;
        TimeoutStartSec =
          lib.foldl' lib.max cfg.timeout (lib.mapAttrsToList (_: check: check.timeout) enabled) + 60;
      };
    };
  };
}
