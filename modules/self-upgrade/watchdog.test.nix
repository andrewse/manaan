# How a hung boot is made to end in a reboot. What self-upgrade-deadline does
# when it fires is in deadline.test.sh, and a hung release rolled back across
# reboots in tests/integration/rollback.test.sh.
{ lib, evalModules }:

let
  eval =
    config:
    evalModules [
      ./default.nix
      ../healthchecks/default.nix
      # notify.nix's, standing in for it: no notifications.
      { options.machine.notify.onFailure = lib.mkOption { default = [ ]; }; }
      { boot.loader.systemd-boot.enable = true; }
      # modules/system/users.nix, which the signers default to.
      {
        options.machine.users = lib.mkOption { type = with lib.types; attrsOf (listOf str); };
        config.machine.users.alice = [ "ssh-ed25519 AAAAalice alice@laptop" ];
      }
      config
    ];
  # The slowest service there is, as Sonarr, Radarr and NZBHydra2 are.
  slow = {
    machine.selfUpgrade.enable = true;
    machine.healthchecks.services.slow = {
      url = "http://127.0.0.1:8000/ping";
      startTimeout = 900;
    };
  };
  enabled = eval slow;
  deadline = enabled.systemd.services.self-upgrade-deadline;
in
{
  "the kernel or PID 1 hanging, on any boot: softdog, from stage 1, pinged by PID 1" = {
    expr = {
      softdog = lib.elem "softdog" enabled.boot.initrd.kernelModules;
      inherit (enabled.systemd.settings.Manager) RuntimeWatchdogSec;
    };
    expected = {
      softdog = true;
      RuntimeWatchdogSec = "1min";
    };
  };

  "a soft lockup panics, and so reboots; a hung task doesn't, as endor's NFS makes them" = {
    expr = {
      softlockup = lib.elem "softlockup_panic=1" enabled.boot.kernelParams;
      hungTask =
        lib.any (lib.hasPrefix "hung_task_panic") enabled.boot.kernelParams
        || (enabled.boot.kernel.sysctl."kernel.hung_task_panic" or 0) != 0;
    };
    expected = {
      softlockup = true;
      hungTask = false;
    };
  };

  "the deadline only acts while an upgrade is on trial" = {
    expr = {
      inherit (deadline.unitConfig) ConditionPathExists;
      inherit (deadline) restartIfChanged;
      inherit (enabled.systemd.timers.self-upgrade-deadline) wantedBy;
    };
    expected = {
      ConditionPathExists = "/var/lib/self-upgrade/pending";
      restartIfChanged = false;
      wantedBy = [ "timers.target" ];
    };
  };

  "the deadline is ten minutes past the longest the healthchecks may take" = {
    expr = {
      healthchecks = enabled.systemd.services.healthcheck.serviceConfig.TimeoutStartSec;
      inherit (enabled.systemd.timers.self-upgrade-deadline.timerConfig) OnBootSec;
    };
    expected = {
      # The service's 900s, a minute for it to start in, and a minute more.
      healthchecks = 1020;
      OnBootSec = 1620;
    };
  };

  "a deadline the healthchecks could outlast: refused" = {
    expr = map (a: a.message) (
      lib.filter (a: !a.assertion && lib.hasPrefix "machine.selfUpgrade.trialDeadline" a.message)
        (eval (lib.recursiveUpdate slow { machine.selfUpgrade.trialDeadline = 1020; })).assertions
    );
    expected = [
      "machine.selfUpgrade.trialDeadline (1020s) must be longer than the healthchecks may take (1020s)."
    ];
  };
}
