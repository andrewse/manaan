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
    users.users.git = {
      isSystemUser = true;
      description = "git server";
      group = "git";
      home = cfg.repoDir;
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

    machine.healthchecks.checks.git-repo-dir = {
      type = "command";
      target = "test -d ${lib.escapeShellArg cfg.repoDir}";
    };
  };
}
