# Ports reachable only from private networks. Tailscale is trusted separately
# (see services/tailscale.nix), so these are also reachable over the tailnet.
{ config, lib, ... }:

let
  cfg = config.machine.firewall;
  internalV4 = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
  ];
  internalV6 = [
    "fc00::/7"
    "fe80::/10"
  ];
  set = list: "{ ${lib.concatMapStringsSep ", " toString list} }";
  rules = proto: ports: ''
    ip saddr ${set internalV4} ${proto} dport ${set ports} accept
    ip6 saddr ${set internalV6} ${proto} dport ${set ports} accept
  '';
in
{
  options.machine.firewall = {
    internalTCPPorts = lib.mkOption {
      type = with lib.types; listOf port;
      default = [ ];
      description = "TCP ports open to private networks and Tailscale only.";
    };
    internalUDPPorts = lib.mkOption {
      type = with lib.types; listOf port;
      default = [ ];
      description = "UDP ports open to private networks and Tailscale only.";
    };
  };

  config.networking.firewall.extraInputRules = lib.concatStrings [
    (lib.optionalString (cfg.internalTCPPorts != [ ]) (rules "tcp" cfg.internalTCPPorts))
    (lib.optionalString (cfg.internalUDPPorts != [ ]) (rules "udp" cfg.internalUDPPorts))
  ];
}
