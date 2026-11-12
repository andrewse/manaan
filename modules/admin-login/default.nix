# An admin login for the web UIs of Syncthing, SABnzbd and NZBHydra2, which
# would have none until one is set in each, while they are open to every
# private network (machine.firewall). The first time a service starts without
# a login, it is given `admin` and a random password, kept as a systemd
# credential in /etc/credstore, root's alone:
#   sudo cat /etc/credstore/sabnzbd-admin
# A service that has a login, made here or in its web UI, is left alone, so
# one changed in the web UI sticks, and none is made for it.
#
# Each service gets two steps, around its own script:
# - <service>-admin-login-generate.service, as root, before the unit that
#   sets the login: while the service has no login and none is kept, makes
#   one in /etc/credstore/<service>-admin (generate.sh). The unit that sets it
#   requires it, so a service whose login can't be made doesn't start open.
#   It is a unit of its own, not an ExecStartPre=+ in the service's: systemd
#   260 would load the credential for the steps after one made that way too
#   (each ExecStartPre= gets a fresh credential store), but only since that
#   change; a unit before it doesn't depend on when systemd reads the store.
# - setting it, as the service's user in its sandbox (login.sh), from the
#   credential, which ImportCredential= finds in /etc/credstore and skips when
#   it isn't there. It sets nothing once the service has a login.
{
  config,
  lib,
  pkgs,
  machineLib,
  ...
}:

let
  credstore = "/etc/credstore";
  credential = name: "${name}-admin";
  generator = name: "${name}-admin-login-generate";

  script =
    name: suffix: part: runtimeInputs: vars:
    lib.getExe (
      machineLib.mkScript {
        name = "${name}-${suffix}";
        inherit runtimeInputs vars;
        parts = [
          ./${name}.sh
          part
        ];
      }
    );

  # The unit that makes the login, before the unit named `consumer` sets it.
  generate =
    name:
    {
      consumer,
      after ? [ ],
      runtimeInputs,
      vars,
    }:
    {
      ${generator name} = {
        description = "Make a login for ${name}, if it has none and none is kept";
        before = [ consumer ];
        inherit after;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = script name "admin-login-generate" ./generate.sh runtimeInputs (
            vars
            // {
              service = name;
              file = "${credstore}/${credential name}";
            }
          );
          # Root, to write the credential store, but only that; it reads the
          # service's config and nothing else.
          ProtectSystem = "strict";
          ReadWritePaths = [ credstore ];
          ProtectHome = true;
          PrivateTmp = true;
          PrivateNetwork = true;
        };
      };
    };

  # What the unit that sets the login adds: the unit that makes it, and the
  # credential. The credential is the unit's, so for SABnzbd and NZBHydra2 the
  # service itself can read it too; it is its own password, which it keeps in
  # its config anyway. systemd sets credentials up per unit, not per command,
  # so the setting step can't have it alone; a unit of its own before the
  # service could, but SABnzbd's login has to reach the module's preStart in
  # the service's unit.
  consumes = name: {
    requires = [ "${generator name}.service" ];
    after = [ "${generator name}.service" ];
    serviceConfig.ImportCredential = credential name;
  };

  set =
    name: runtimeInputs: vars:
    script name "admin-login" ./login.sh runtimeInputs (vars // { credential = credential name; });

  syncthing = config.services.syncthing;
  sabnzbd = config.services.sabnzbd;
  nzbhydra2 = config.services.nzbhydra2;
  # What sabnzbd.sh writes for the module to merge, in the unit's own /run.
  sabnzbdLogin = "/run/sabnzbd/admin-login.ini";

  syncthingInputs = [
    pkgs.libxml2
    pkgs.jq
    pkgs.curl
    pkgs.coreutils
  ];
  syncthingVars = {
    config_dir = syncthing.configDir;
    address = syncthing.guiAddress;
  };
  sabnzbdInputs = [
    pkgs.gawk
    pkgs.coreutils
  ];
  sabnzbdVars = {
    ini = "/var/lib/${sabnzbd.stateDir}/sabnzbd.ini";
    out = sabnzbdLogin;
  };
  nzbhydra2Inputs = [
    pkgs.yq-go
    pkgs.mkpasswd
    pkgs.coreutils
  ];
  nzbhydra2Vars = {
    config = "${nzbhydra2.dataDir}/nzbhydra.yml";
    # What NZBHydra2 writes nzbhydra.yml from, from the same source as its jar.
    base = "${nzbhydra2.package.src}/core/src/main/resources/config/baseConfig.yml";
  };
in
{
  config = lib.mkMerge [
    # As systemd's own tmpfiles.d/credstore.conf, which NixOS doesn't install.
    (lib.mkIf (syncthing.enable || sabnzbd.enable || nzbhydra2.enable) {
      systemd.tmpfiles.settings.credstore.${credstore}.d = {
        mode = "0700";
        user = "root";
        group = "root";
      };
    })

    # A unit of its own, like the module's syncthing-init (which a host only
    # has once it gives Syncthing settings): it runs whenever Syncthing starts,
    # once it has, and after syncthing-init if there is one. A failure fails
    # this unit, not Syncthing. Sandboxed as machine.sandbox would, but not in
    # it: that wants a user of its own per unit, and a process in it to check.
    (lib.mkIf syncthing.enable {
      systemd.services =
        generate "syncthing" {
          consumer = "syncthing-admin-login.service";
          # It reads config.xml, which Syncthing writes as it starts.
          after = [ "syncthing.service" ];
          runtimeInputs = syncthingInputs;
          vars = syncthingVars;
        }
        // {
          syncthing-admin-login = lib.mkMerge [
            (consumes "syncthing")
            {
              description = "Give Syncthing's GUI a login, the first time it has none";
              requires = [ "syncthing.service" ];
              after = [
                "syncthing.service"
                "syncthing-init.service"
              ];
              wantedBy = [ "syncthing.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                User = syncthing.user;
                Group = syncthing.group;
                ExecStart = set "syncthing" syncthingInputs syncthingVars;
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateTmp = true;
              };
            }
          ];
        };
    })

    # Before the module's preStart, which merges sabnzbdLogin over sabnzbd.ini.
    (lib.mkIf sabnzbd.enable {
      services.sabnzbd.secretFiles = [ sabnzbdLogin ];
      systemd.services =
        generate "sabnzbd" {
          consumer = "sabnzbd.service";
          runtimeInputs = sabnzbdInputs;
          vars = sabnzbdVars;
        }
        // {
          sabnzbd = lib.mkMerge [
            (consumes "sabnzbd")
            {
              serviceConfig = {
                RuntimeDirectory = "sabnzbd";
                RuntimeDirectoryMode = "0700";
                ExecStartPre = lib.mkBefore [ (set "sabnzbd" sabnzbdInputs sabnzbdVars) ];
              };
            }
          ];
        };
    })

    (lib.mkIf nzbhydra2.enable {
      systemd.services =
        generate "nzbhydra2" {
          consumer = "nzbhydra2.service";
          runtimeInputs = nzbhydra2Inputs;
          vars = nzbhydra2Vars;
        }
        // {
          nzbhydra2 = lib.mkMerge [
            (consumes "nzbhydra2")
            { serviceConfig.ExecStartPre = [ (set "nzbhydra2" nzbhydra2Inputs nzbhydra2Vars) ]; }
          ];
        };
    })
  ];
}
