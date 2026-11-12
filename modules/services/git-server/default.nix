# Bare git repos over SSH as the `git` user, e.g.
#   git push ssh://git@manaan/project.git main
# Pushing to a repo that doesn't exist creates it.
{
  config,
  lib,
  pkgs,
  machineLib,
  ...
}:

let
  cfg = config.machine.gitServer;
  wrapper = machineLib.mkScript {
    name = "git-ssh-wrapper";
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
      pkgs.util-linux
    ];
    vars.repo_dir = cfg.repoDir;
    parts = [ ./wrapper.sh ];
  };
in
{
  options.machine.gitServer = {
    enable = lib.mkEnableOption "the SSH git server";
    repoDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/git";
      description = "Where the bare repositories live.";
    };
  };

  config = lib.mkIf cfg.enable {
    # It has no unit to hold back, so off it still answers over SSH: what
    # waits for the host to list it is the healthcheck on repoDir, which on a
    # network share would fail the boot healthchecks while the share is
    # missing or down.
    machine.autostart.git-server = lib.mkDefault false;
    machine.autostartUnitless = [ "git-server" ];

    users.users.git = {
      isSystemUser = true;
      description = "git server";
      group = "git";
      # Local even when repoDir is a network share, so activation neither
      # waits on the share nor chowns it. A repoDir elsewhere must already
      # exist, writable by git.
      home = "/var/lib/git";
      createHome = true;
      homeMode = "750";
      # sshd runs the ForceCommand through the login shell.
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = map (key: "restrict ${key}") (
        lib.concatLists (lib.attrValues config.machine.users)
      );
    };
    users.groups.git = { };

    services.openssh.extraConfig = ''
      Match User git
        ForceCommand ${lib.getExe wrapper}
        PermitTTY no
    '';

    programs.git = {
      enable = true;
      config.init.defaultBranch = "main";
    };

    # It has no unit of its own: the wrapper logs each push, pull and refusal
    # as git-server.
    machine.serviceCommands.git-server.journal = [ "--identifier=git-server" ];

    # Through repoDir rather than at it: when repoDir is an automount point,
    # as a network share mounted on first use is, a stat of the point itself
    # neither mounts it nor fails, and so finds the empty directory the
    # automount sits on whether or not the share is there. A path inside it
    # has to be mounted to resolve, so it fails while the share can't be.
    machine.healthchecks.checks.git-repo-dir = {
      enable = config.machine.autostart.git-server;
      type = "command";
      target = "test -d ${lib.escapeShellArg "${cfg.repoDir}/."}";
    };
  };
}
