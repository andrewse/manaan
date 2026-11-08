# A host with every service in modules/services/ switched off, or every one
# switched on, but SSH and Tailscale, which every host runs. Each module does
# nothing until it is switched on and keeps the host's promises alongside any
# of the others, so the host's cases (host/) hold either way. Only the switch
# moves: the host's own settings for a service stay, as they would if the host
# switched it.
{ lib }:

let
  # By file in modules/services/, the option that switches it on.
  switches = {
    "cadvisor.nix" = [
      "services"
      "cadvisor"
      "enable"
    ];
    "docker.nix" = [
      "virtualisation"
      "docker"
      "enable"
    ];
    "gatus.nix" = [
      "services"
      "gatus"
      "enable"
    ];
    "git-server" = [
      "machine"
      "gitServer"
      "enable"
    ];
    "grafana" = [
      "services"
      "grafana"
      "enable"
    ];
    "node-exporter.nix" = [
      "services"
      "prometheus"
      "exporters"
      "node"
      "enable"
    ];
    "nzbhydra2.nix" = [
      "services"
      "nzbhydra2"
      "enable"
    ];
    "prometheus.nix" = [
      "services"
      "prometheus"
      "enable"
    ];
    "radarr.nix" = [
      "services"
      "radarr"
      "enable"
    ];
    "sabnzbd.nix" = [
      "services"
      "sabnzbd"
      "enable"
    ];
    "sonarr.nix" = [
      "services"
      "sonarr"
      "enable"
    ];
    "syncthing.nix" = [
      "services"
      "syncthing"
      "enable"
    ];
  };
  notSwitched = [
    "default.nix"
    "ssh.nix"
    "tailscale.nix"
  ];
in
{
  module = enable: {
    config = lib.mkMerge (
      map (path: lib.setAttrByPath path (lib.mkForce enable)) (lib.attrValues switches)
    );
  };

  cases = enable: config: {
    "every service in modules/services/ is switched, but SSH and Tailscale" = {
      expr = lib.attrNames switches;
      expected = lib.attrNames (removeAttrs (builtins.readDir ../../modules/services) notSwitched);
    };

    "every service is ${if enable then "on" else "off"}" = {
      expr = lib.attrNames (
        lib.filterAttrs (_: path: lib.getAttrFromPath path config != enable) switches
      );
      expected = [ ];
    };

    # A failed assertion fails this too; its message is in the assertions case.
    "the whole system evaluates" = {
      expr = (builtins.tryEval config.system.build.toplevel.drvPath).success;
      expected = true;
    };
  };
}
