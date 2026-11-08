# What the system tests run, for one host: its installer ISO, installing the
# host as tested, and host.json, what the tests need to know about its config.
# Building this is the only part of the system tests that needs Nix;
# tests/system/*.py boot it in QEMU on macOS or Linux, with that QEMU's own UEFI
# firmware, and see the host only as a user would.
{
  pkgs,
  name,
  modules,
  mkHost,
  mkInstaller,
}:

let
  inherit (pkgs) lib;

  tested = extra: mkHost (modules ++ [ ./tested.nix ] ++ extra);
  release = extra: (tested [ extra ]).config.system.build.toplevel;

  # What the upgrade test publishes to the release branch, one at a time.
  releases = {
    good = release { environment.etc.release.text = "good"; };
    fails-healthchecks = release {
      machine.healthchecks.checks.release = {
        type = "command";
        target = "false";
      };
      machine.healthchecks.timeout = 10;
    };
    # Stage 1 can't find the root volume, like a bad change to the disk layout.
    unbootable = release {
      fileSystems."/".device = lib.mkForce "/dev/pool/missing";
      fileSystems."/".options = [ "x-systemd.device-timeout=10s" ];
    };
  };

  # The host the ISO installs, with the releases already in its store.
  host = tested [ { system.extraDependencies = lib.attrValues releases; } ];
  cfg = host.config;
  installer = (mkInstaller host).config;

  facts = {
    inherit name releases;
    arch = pkgs.stdenv.hostPlatform.qemuArch;
    installed = cfg.system.build.toplevel;
    sandbox = lib.mapAttrsToList (unit: s: {
      inherit unit;
      inherit (s) root writes;
    }) cfg.machine.sandbox;
    stopped = lib.attrNames (
      lib.filterAttrs (
        unit: start: !start && !lib.elem unit cfg.machine.autostartUnitless
      ) cfg.machine.autostart
    );
    serviceCommands = lib.attrNames cfg.machine.serviceCommands;
  };

  # A disk that is already in use, which the installer must leave alone.
  used = pkgs.runCommand "used-disk" { nativeBuildInputs = [ pkgs.e2fsprogs ]; } ''
    truncate -s 1G $out
    mkfs.ext4 -q $out
  '';
in
assert lib.assertMsg (
  lib.attrNames cfg.disko.devices.disk == [ "main" ]
) "The system tests give the host one disk, disko's `main`, at /dev/vda.";
pkgs.runCommand "system-test-${name}" { } ''
  mkdir $out
  ln -s ${installer.system.build.isoImage}/iso/${installer.image.fileName} $out/installer.iso
  ln -s ${used} $out/used.raw
  ln -s ${pkgs.writeText "host.json" (builtins.toJSON facts)} $out/host.json
''
