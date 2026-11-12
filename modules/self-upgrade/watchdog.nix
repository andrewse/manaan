# A boot that hangs, rather than failing, must end in a reboot too: the
# one-shot entry is used up by then, so a reboot lands on the previous system
# and self-upgrade-verify rolls the upgrade back. Two layers:
#
#   every boot   the kernel or PID 1 stops making progress: a watchdog reboots
#   trial boot   userspace never gets as far as self-upgrade-verify deciding:
#                self-upgrade-deadline reboots once the deadline has passed
{
  config,
  lib,
  pkgs,
  machineLib,
  ...
}:

let
  cfg = config.machine.selfUpgrade;
  stateDir = "/var/lib/self-upgrade";
  # The longest the healthchecks may take, from when they start; verify waits
  # for them. None without the healthchecks module, as in some unit tests.
  healthchecks = config.systemd.services.healthcheck.serviceConfig.TimeoutStartSec or 0;
in
{
  options.machine.selfUpgrade.trialDeadline = lib.mkOption {
    type = lib.types.ints.positive;
    # Ten minutes for booting as far as the healthchecks, and for verify itself.
    default = healthchecks + 600;
    defaultText = lib.literalExpression "config.systemd.services.healthcheck.serviceConfig.TimeoutStartSec + 600";
    description = ''
      Seconds after boot by which self-upgrade-verify must have decided an
      upgrade on trial; a trial boot that hasn't is rebooted, onto the previous
      system. Longer than the healthchecks may take, so only a hang reaches it.
    '';
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.trialDeadline > healthchecks;
        message = "machine.selfUpgrade.trialDeadline (${toString cfg.trialDeadline}s) must be longer than the healthchecks may take (${toString healthchecks}s).";
      }
    ];

    # There is no hardware watchdog in the VM, so softdog stands in for one. It
    # is loaded in stage 1 so the device is there when PID 1 starts. PID 1 pings
    # it; if PID 1 hangs, or the kernel stops running timers, it reboots. The
    # same device arms systemd's reboot watchdog, which defaults to 10 minutes,
    # so a reboot that hangs after the services have stopped is forced through.
    boot.initrd.kernelModules = [ "softdog" ];
    systemd.settings.Manager.RuntimeWatchdogSec = "1min";

    # A soft lockup (a CPU stuck in the kernel) panics, and panic=10 reboots.
    # Hung tasks are left alone: endor's NFS shares (hosts/manaan/mounts.nix)
    # put anything reading them into uninterruptible sleep while endor doesn't
    # answer, and panicking on that would turn an outage of endor's into a
    # reboot loop here.
    boot.kernelParams = [ "softlockup_panic=1" ];

    systemd.services.self-upgrade-deadline = {
      description = "Reboot a trial boot that self-upgrade-verify hasn't decided in time";
      # Checked when the deadline passes: verify removes it once it has decided.
      unitConfig.ConditionPathExists = "${stateDir}/pending";
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        # A graceful reboot, as verify's own is. If stopping the services
        # hangs, reboot.target's 30-minute job timeout forces it, and the
        # reboot watchdog above covers what follows.
        ExecStart = lib.getExe (
          machineLib.mkScript {
            name = "self-upgrade-deadline";
            runtimeInputs = [
              pkgs.coreutils
              config.systemd.package
            ];
            vars = {
              state = stateDir;
              booted_system = "/run/booted-system";
              deadline = cfg.trialDeadline;
            };
            parts = [ ./deadline.sh ];
          }
        );
      };
    };

    systemd.timers.self-upgrade-deadline = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnBootSec = cfg.trialDeadline;
    };
  };
}
