# Pull-based upgrades with automatic rollback.
#
#   self-upgrade.timer   -> self-upgrade.service: fetch the release branch, build it,
#                           make it a one-shot boot entry (old system stays default), reboot
#   boot                 -> smoke-test.service -> self-upgrade-verify.service:
#                           pass: make the new system the default
#                           fail, or the new system never came up: roll back, remember
#                           the commit as bad, and skip it until the branch moves
#
# State lives in /var/lib/self-upgrade: `rev` (deployed commit), `bad-revs`, and
# `pending` (while an upgrade is on trial).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.machine.selfUpgrade;
  stateDir = "/var/lib/self-upgrade";

  mkScript =
    name: vars: text:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.git
        pkgs.gnugrep
        config.nix.package
        config.systemd.package
      ];
      text =
        lib.toShellVars (
          {
            state = stateDir;
            profile = "/nix/var/nix/profiles/system";
          }
          // vars
        )
        + "\n"
        + builtins.readFile ./lib.sh
        + text;
    };
in
{
  options.machine.selfUpgrade = {
    enable = lib.mkEnableOption "pulling and applying this repo's release branch";
    repo = lib.mkOption {
      type = lib.types.str;
      default = "andrewse/machine_configs";
      description = "GitHub owner/repo to pull from.";
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/${cfg.repo}";
      defaultText = lib.literalExpression ''"https://github.com/''${config.machine.selfUpgrade.repo}"'';
      description = "Git URL polled for new commits on the branch.";
    };
    build = lib.mkOption {
      type = lib.types.str;
      internal = true;
      default = ''
        nix build --no-link --print-out-paths \
          "github:${cfg.repo}/$1#nixosConfigurations.${config.networking.hostName}.config.system.build.toplevel"
      '';
      description = ''
        Shell commands that build this host's system at commit $1 and print its store path.
        The VM test replaces it, as it has no GitHub to build from.
      '';
    };
    branch = lib.mkOption {
      type = lib.types.str;
      default = "release";
      description = "Branch to deploy. CI fast-forwards it to main once checks pass.";
    };
    dates = lib.mkOption {
      type = lib.types.str;
      default = "*:0/30";
      description = "systemd OnCalendar expression for checking for a new release.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.boot.loader.systemd-boot.enable;
        message = "machine.selfUpgrade relies on systemd-boot one-shot boot entries.";
      }
    ];

    # Make every failure to boot end in a reboot, which lands on the old system:
    # a stage-1 failure panics instead of opening a shell, a panic reboots, and
    # stage 2 carries on past failed mounts so the smoke tests can catch it.
    boot.kernelParams = [
      "boot.panic_on_fail"
      "panic=10"
    ];
    systemd.enableEmergencyMode = false;

    systemd.services.self-upgrade = {
      description = "Pull and stage the ${cfg.branch} branch";
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "self-upgrade-verify.service"
      ];
      unitConfig.ConditionPathExists = "!${stateDir}/pending";
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe (
          mkScript "self-upgrade" { inherit (cfg) url branch; } (
            ''
              build_system() {
              ${cfg.build}
              }
            ''
            + builtins.readFile ./upgrade.sh
          )
        );
      };
    };

    systemd.timers.self-upgrade = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.dates;
        RandomizedDelaySec = "5min";
        Persistent = true;
      };
    };

    systemd.services.self-upgrade-verify = {
      description = "Confirm or roll back a pending upgrade";
      wantedBy = [ "multi-user.target" ];
      wants = [ "smoke-test.service" ];
      after = [ "smoke-test.service" ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe (mkScript "self-upgrade-verify" { } (builtins.readFile ./verify.sh));
      };
    };

    # The rollback target must survive until the trial boot has been decided.
    systemd.services.nix-gc = lib.mkIf config.nix.gc.automatic {
      unitConfig.ConditionPathExists = "!${stateDir}/pending";
    };
  };
}
