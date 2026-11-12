# manaan's own: its disk layout and endor's shares.
{ lib, config }:

let
  fs = config.fileSystems;
  # The mount, its volume in the pool, and the options it must have.
  volumes = [
    [
      "/"
      "root"
      [ ]
    ]
    [
      "/nix"
      "nix"
      [ ]
    ]
    [
      "/var"
      "var"
      [ "nodev" ]
    ]
    [
      "/home"
      "home"
      [
        "nodev"
        "nosuid"
      ]
    ]
    [
      "/tmp"
      "tmp"
      [
        "nodev"
        "nosuid"
      ]
    ]
    [
      "/var/lib/docker"
      "docker"
      [ ]
    ]
    [
      "/var/lib/grafana"
      "grafana"
      [
        "nodev"
        "nosuid"
      ]
    ]
    [
      "/var/lib/prometheus2"
      "prometheus"
      [
        "nodev"
        "nosuid"
      ]
    ]
  ];
  shares = lib.filterAttrs (mount: _: lib.hasPrefix "/mnt/endor/" mount) fs;
  git = config.machine.gitServer;
  inherit (config.machine.healthchecks) checks;
in
{
  "each mount is its own volume, with its mount options" = {
    expr = lib.filter (
      v:
      let
        mount = lib.elemAt v 0;
      in
      !(fs ? ${mount})
      || fs.${mount}.device != "/dev/pool/${lib.elemAt v 1}"
      || !lib.all (o: lib.elem o fs.${mount}.options) (lib.elemAt v 2)
    ) volumes;
    expected = [ ];
  };

  "endor's shares are mounted on first use, so the host boots without them" = {
    expr = lib.attrNames (
      lib.filterAttrs (
        _: share: !(lib.elem "x-systemd.automount" share.options && lib.elem "nofail" share.options)
      ) shares
    );
    expected = [ ];
  };

  # A stat of an automount point finds the directory it sits on, mounted or
  # not; only a path inside it mounts it, or fails when it can't.
  "the git server's healthcheck looks into the repos share, not at its automount" = {
    expr = lib.optional (
      git.enable && !lib.hasInfix "${git.repoDir}/" checks.git-repo-dir.target
    ) checks.git-repo-dir.target;
    expected = [ ];
  };

  "syncthing makes its own keys rather than being handed the old host's" = {
    expr = {
      inherit (config.services.syncthing) cert key;
    };
    expected = {
      cert = null;
      key = null;
    };
  };
}
