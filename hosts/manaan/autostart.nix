# What starts at boot, besides SSH, the healthchecks and self-upgrade, which
# always do. A service switched on in default.nix is installed, and
# `systemctl start <unit>` runs it to try it out, but it only starts at boot
# once it is listed here as true. See modules/system/autostart.nix.
{
  machine.autostart = {
    # Tailscale: until it is on, SSH in over the local network.
    # tailscaled = true;
    # docker = true;
    # syncthing = true;
    # nzbhydra2 = true;
    # sonarr = true;
    # radarr = true;
    # sabnzbd = true;
    # prometheus = true;
    # prometheus-node-exporter = true;
    # cadvisor = true;
    # grafana = true;
    # gatus = true;
    # The git server answers over SSH either way; this adds its healthcheck,
    # which needs endor's repos share to exist and be up.
    git-server = true;
  };
}
