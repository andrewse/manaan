# How self-upgrade is wired into boot. The scripts' own logic is in
# upgrade.test.sh and verify.test.sh, and the two together across reboots in
# tests/integration/rollback.test.sh; this is what those take for granted.
{ lib, evalModules }:

let
  eval =
    config:
    evalModules [
      ./default.nix
      { boot.loader.systemd-boot.enable = true; }
      config
    ];
  enabled = eval { machine.selfUpgrade.enable = true; };
  services = enabled.systemd.services;
in
{
  "verify runs on every boot, once the healthchecks have decided" = {
    expr = lib.getAttrs [ "wants" "after" "wantedBy" ] services.self-upgrade-verify;
    expected = {
      wants = [ "healthcheck.service" ];
      after = [ "healthcheck.service" ];
      wantedBy = [ "multi-user.target" ];
    };
  };

  "an upgrade waits for this boot's to be decided, and doesn't start while one is on trial" = {
    expr = {
      after = lib.elem "self-upgrade-verify.service" services.self-upgrade.after;
      inherit (services.self-upgrade.unitConfig) ConditionPathExists;
    };
    expected = {
      after = true;
      ConditionPathExists = "!/var/lib/self-upgrade/pending";
    };
  };

  "neither is restarted by a switch, which would cut an upgrade off part way" = {
    expr = map (s: s.restartIfChanged) [
      services.self-upgrade
      services.self-upgrade-verify
    ];
    expected = [
      false
      false
    ];
  };

  "garbage collection keeps the system to roll back to while an upgrade is on trial" = {
    expr =
      (eval {
        machine.selfUpgrade.enable = true;
        nix.gc.automatic = true;
      }).systemd.services.nix-gc.unitConfig.ConditionPathExists;
    expected = "!/var/lib/self-upgrade/pending";
  };

  "a boot that fails anywhere ends in a reboot, onto the kept release" = {
    expr = {
      params = lib.filter (p: p == "boot.panic_on_fail" || p == "panic=10") enabled.boot.kernelParams;
      emergencyMode = enabled.systemd.enableEmergencyMode;
    };
    expected = {
      params = [
        "boot.panic_on_fail"
        "panic=10"
      ];
      emergencyMode = false;
    };
  };

  "no systemd-boot, so no one-shot boot entries: refused" = {
    expr = map (a: a.message) (
      lib.filter (a: !a.assertion && lib.hasPrefix "machine.selfUpgrade" a.message)
        (eval {
          machine.selfUpgrade.enable = true;
          boot.loader.systemd-boot.enable = lib.mkForce false;
        }).assertions
    );
    expected = [ "machine.selfUpgrade relies on systemd-boot one-shot boot entries." ];
  };
}
