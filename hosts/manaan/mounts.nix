# Shares on endor, the TrueNAS host this VM runs on. Each is mounted on first
# access rather than at boot, so manaan boots (and passes its healthchecks)
# whether or not endor is serving them yet.
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
in
{
  fileSystems = {
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

  machine.secrets.use = [ "smb-credentials" ];
}
