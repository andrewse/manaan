# Pull-based upgrades with automatic rollback.
#
#   self-upgrade.timer   -> self-upgrade.service: fetch the release branch into a
#                           clone of its own; refuse its tip unless an admin signed
#                           it and it descends from the deployed commit; build
#                           exactly that commit, make it a one-shot boot entry (old
#                           system stays default), reboot
#   boot                 -> healthcheck.service -> self-upgrade-verify.service:
#                           pass: make the new system the default
#                           fail, or the new system never came up: roll back and
#                           record the failed attempt; a later run tries the commit
#                           again, until it has failed `attempts` times, and then
#                           skips it until the branch moves
#
# The branch comes from `url`, GitHub, unless `gitServerRepo` names a repo on
# this host's own git server: then the timer fetches it from there, and
# `systemctl start self-upgrade-github` fetches it from `url` instead, for when
# the git server can't serve it. Either is verified the same way.
#
# State lives in /var/lib/self-upgrade: `rev` (deployed commit), `bad-revs` (one
# line per failed attempt), `pending` (while an upgrade is on trial), `lock`
# (while either is running), and `repo`, the bare clone of the branch that
# commits are verified and built from.
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
  # A host that switches its git server off upgrades from url as before.
  fromGitServer = cfg.gitServerRepo != null && config.machine.gitServer.enable;

  # git's gpg.ssh.allowedSignersFile: each key may sign commits (the "git"
  # namespace) as the user it belongs to. The Makefile's `signed` target makes
  # the same file from ssh/ for itself.
  allowedSigners = lib.concatStrings (
    lib.mapAttrsToList (
      user: keys: lib.concatMapStrings (key: "${user} namespaces=\"git\" ${key}\n") keys
    ) cfg.signers
  );

  # Each script starts with lib.sh, after the shared variables and its own.
  mkScript =
    name: vars: parts:
    machineLib.mkScript {
      inherit name;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.git
        pkgs.gnugrep
        # flock, and runuser for reading the git server's repo as git.
        pkgs.util-linux
        # ssh-keygen, which git verifies SSH signatures with.
        pkgs.openssh
        config.nix.package
        config.systemd.package
      ];
      vars = {
        state = stateDir;
        profile = "/nix/var/nix/profiles/system";
        inherit (cfg) attempts;
      }
      // vars;
      parts = [ ./lib.sh ] ++ parts;
    };

  # upgradeService <name> <description> <vars>: the unit that fetches the
  # branch as <vars> say (`url`, `upload_pack`, `fallback`) and stages it.
  upgradeService = name: description: vars: {
    inherit description;
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
        mkScript name
          (
            {
              inherit (cfg) branch;
              signers = toString cfg.allowedSignersFile;
              current_system = "/run/current-system";
              upload_pack = "";
              fallback = "";
            }
            // vars
          )
          [
            ''
              build_system() {
              ${cfg.build}
              }
            ''
            ./upgrade.sh
          ]
      );
    };
  };
in
{
  imports = [ ./watchdog.nix ];

  options.machine.selfUpgrade = {
    enable = lib.mkEnableOption "pulling and applying this repo's release branch";
    url = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/andrewse/manaan";
      description = ''
        Git URL the branch is fetched from, and so the system built. With
        gitServerRepo set, only self-upgrade-github fetches from it.
      '';
    };
    gitServerRepo = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "manaan.git";
      description = ''
        A repo on this host's own git server (machine.gitServer) to fetch the
        branch from instead of url, read as the git user, as a pull through the
        server would be. url is then only the fallback: nothing fetches from it
        but `systemctl start self-upgrade-github`. Ignored while the git server
        is off.
      '';
    };
    signers = lib.mkOption {
      type = with lib.types; attrsOf (listOf str);
      default = config.machine.users;
      defaultText = lib.literalExpression "config.machine.users";
      description = ''
        Who may sign a release, and their SSH public keys: only a branch tip
        signed by one of these keys is deployed.
      '';
    };
    allowedSignersFile = lib.mkOption {
      type = lib.types.path;
      internal = true;
      default = pkgs.writeText "allowed_signers" allowedSigners;
      defaultText = lib.literalMD "made from `signers`";
      description = ''
        git's gpg.ssh.allowedSignersFile for checking a release's signature.
        The VM test replaces it, as its key is made for each run.
      '';
    };
    build = lib.mkOption {
      type = lib.types.str;
      internal = true;
      default = ''
        nix build --no-link --print-out-paths \
          "git+file://$clone?rev=$1#nixosConfigurations.${config.networking.hostName}.config.system.build.toplevel"
      '';
      description = ''
        Shell commands that build this host's system at commit $1, which is in the
        bare clone at $clone, and print its store path. The VM test replaces it,
        as it can't build the host.
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
    attempts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = ''
        Trial boots a release gets before it is skipped until the branch moves.
        A failed trial is tried again on a later run, so that one transient
        outage (the file server down, the network blipping) does not rule out a
        good release.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.boot.loader.systemd-boot.enable;
        message = "machine.selfUpgrade relies on systemd-boot one-shot boot entries.";
      }
      {
        assertion = lib.concatLists (lib.attrValues cfg.signers) != [ ];
        message = "machine.selfUpgrade.signers has no keys, so no release could ever be deployed.";
      }
    ];

    # Make every failure to boot end in a reboot, which lands on the old system:
    # a stage-1 failure panics instead of opening a shell, a panic reboots, and
    # stage 2 carries on past failed mounts so the healthchecks can catch it.
    # A boot that hangs instead is rebooted by a watchdog or, if it is a trial
    # boot still undecided at machine.selfUpgrade.trialDeadline, by
    # self-upgrade-deadline (watchdog.nix).
    boot.kernelParams = [
      "boot.panic_on_fail"
      "panic=10"
    ];
    systemd.enableEmergencyMode = false;

    systemd.services.self-upgrade =
      if fromGitServer then
        upgradeService "self-upgrade" "Pull and stage the ${cfg.branch} branch from this host's git server"
          {
            url = "${config.machine.gitServer.repoDir}/${cfg.gitServerRepo}";
            upload_pack = "runuser -u git -- git-upload-pack";
            fallback = "self-upgrade-github";
          }
      else
        upgradeService "self-upgrade" "Pull and stage the ${cfg.branch} branch" { inherit (cfg) url; };

    # Started by hand only, never by the timer.
    systemd.services.self-upgrade-github = lib.mkIf fromGitServer (
      upgradeService "self-upgrade-github" "Pull and stage the ${cfg.branch} branch from ${cfg.url}" {
        inherit (cfg) url;
      }
    );

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
      wants = [ "healthcheck.service" ];
      after = [ "healthcheck.service" ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe (
          mkScript "self-upgrade-verify" {
            booted_system = "/run/booted-system";
          } [ ./verify.sh ]
        );
      };
    };

    # The rollback target must survive until the trial boot has been decided.
    systemd.services.nix-gc = lib.mkIf config.nix.gc.automatic {
      unitConfig.ConditionPathExists = "!${stateDir}/pending";
    };
  };
}
