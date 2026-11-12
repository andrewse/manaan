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
      # modules/system/users.nix, which the signers default to.
      {
        options.machine.users = lib.mkOption { type = with lib.types; attrsOf (listOf str); };
        config.machine.users.alice = [ "ssh-ed25519 AAAAalice alice@laptop" ];
      }
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

  "a release must be signed by an admin's key, as that admin, for git only" = {
    expr =
      (eval {
        machine.selfUpgrade.enable = true;
        machine.users.bob = [
          "ssh-ed25519 AAAAbob1 bob@desktop"
          "ssh-rsa AAAAbob2"
        ];
      }).machine.selfUpgrade.allowedSignersFile.text;
    expected = ''
      alice namespaces="git" ssh-ed25519 AAAAalice alice@laptop
      bob namespaces="git" ssh-ed25519 AAAAbob1 bob@desktop
      bob namespaces="git" ssh-rsa AAAAbob2
    '';
  };

  "no one to sign a release, so nothing could ever deploy: refused" = {
    expr = map (a: a.message) (
      lib.filter (a: !a.assertion && lib.hasPrefix "machine.selfUpgrade" a.message)
        (eval {
          machine.selfUpgrade.enable = true;
          machine.users = lib.mkForce { nobody = [ ]; };
        }).assertions
    );
    expected = [
      "machine.selfUpgrade.signers has no keys, so no release could ever be deployed."
    ];
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
