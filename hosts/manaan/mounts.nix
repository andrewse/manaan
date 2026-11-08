# Shares on endor, the TrueNAS host this VM runs on. Each is mounted on first
# access rather than at boot, so manaan boots (and passes its healthchecks)
# whether or not endor is serving them yet. In the system tests each is a local
# directory instead, open to all as the SMB shares are mounted.
{ config, lib, ... }:

let
  endor = "192.168.2.2";
  automount = [
    "x-systemd.automount"
    "nofail"
    "_netdev"
  ];

  nfs = export: {
    device = "${endor}:/mnt/tank/${export}";
    fsType = "nfs";
    options = [ "nfsvers=4.2" ] ++ automount;
  };

  secrets = config.machine.secrets.paths;
  cifs = share: {
    device = "//${endor}/${share}";
    fsType = "cifs";
    options = [
      "credentials=${secrets.smb-credentials}"
      "iocharset=utf8"
      "uid=3000"
      "gid=3000"
      "file_mode=0777"
      "dir_mode=0777"
    ]
    ++ automount;
  };

  shares = {
    "/mnt/endor/syncthing" = nfs "syncthing";
    "/mnt/endor/pictures" = nfs "pictures";
    "/mnt/endor/movies" = nfs "media/movies";
    "/mnt/endor/series" = nfs "media/series";
    "/mnt/endor/audio" = nfs "media/audio";
    "/mnt/endor/library" = nfs "media/library";
    "/mnt/endor/paperless" = nfs "documents/paperless";
    "/mnt/endor/repos" = nfs "repos";
  }
  # `username=` and `password=` lines (`make secret NAME=smb-credentials`).
  // lib.optionalAttrs (secrets ? smb-credentials) {
    "/mnt/endor/stuff" = cifs "stuff";
    "/mnt/endor/downloads" = cifs "downloads";
  };
in
{
  fileSystems = lib.mkIf (!config.machine.localShares) shares;
  systemd.tmpfiles.settings.endor-shares = lib.mkIf config.machine.localShares (
    lib.mapAttrs (_: _: { d.mode = "0777"; }) shares
  );

  machine.secrets.use = [ "smb-credentials" ];

  # Which service may write which share; `-` because the SMB shares are only
  # there once their secret is. Syncthing's is in syncthing.nix.
  machine.sandbox = lib.mkMerge [
    (lib.mkIf config.services.sonarr.enable {
      sonarr.writes = [
        "/mnt/endor/series"
        "-/mnt/endor/downloads"
      ];
    })
    (lib.mkIf config.services.radarr.enable {
      radarr.writes = [
        "/mnt/endor/movies"
        "-/mnt/endor/downloads"
      ];
    })
    (lib.mkIf config.services.sabnzbd.enable {
      sabnzbd.writes = [ "-/mnt/endor/downloads" ];
    })
  ];
}
