{
  imports = [
    ./hardware.nix
    ./mounts.nix
    ./syncthing.nix
  ];

  machine.users = import ../../ssh;
  machine.gitServer.enable = true;
  machine.selfUpgrade.enable = true;

  # Each set up in modules/services/.
  virtualisation.docker.enable = true;
  services.syncthing.enable = true;
  # Usenet: NZBHydra2 searches indexers, Sonarr (series) and Radarr (movies)
  # pick releases, SABnzbd downloads them. The libraries are on endor's NFS
  # shares (/mnt/endor/series, /mnt/endor/movies); its SMB downloads share is
  # open to all.
  services.nzbhydra2.enable = true;
  services.sonarr.enable = true;
  services.radarr.enable = true;
  services.sabnzbd.enable = true;
  services.prometheus.enable = true;
  services.prometheus.exporters.node.enable = true;
  services.cadvisor.enable = true;
  services.grafana.enable = true;
  services.gatus.enable = true;

  # The same ID as on the old host, so files on endor's NFS shares stay charles's.
  users.users.charles.uid = 1000;

  # The release this machine was first installed with. Never change it after
  # install; it is not the nixpkgs version (that comes from flake.lock).
  system.stateVersion = "26.05";
}
