# What firewall.nix makes of the ports modules open to private networks.
{ lib, evalModules }:

let
  rules =
    ports:
    (evalModules [
      ./firewall.nix
      { machine.firewall = ports; }
    ]).networking.firewall.extraInputRules;
in
{
  "no internal ports: no rules" = {
    expr = rules { };
    expected = "";
  };

  "TCP ports: accepted only from private IPv4 and IPv6 sources" = {
    expr = rules {
      internalTCPPorts = [
        22
        3000
      ];
    };
    expected = ''
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport { 22, 3000 } accept
      ip6 saddr { fc00::/7, fe80::/10 } tcp dport { 22, 3000 } accept
    '';
  };

  "UDP ports: their own rules, after TCP's" = {
    expr = rules {
      internalTCPPorts = [ 22 ];
      internalUDPPorts = [ 21027 ];
    };
    expected = ''
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport { 22 } accept
      ip6 saddr { fc00::/7, fe80::/10 } tcp dport { 22 } accept
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } udp dport { 21027 } accept
      ip6 saddr { fc00::/7, fe80::/10 } udp dport { 21027 } accept
    '';
  };

  "a port opened by two modules: merged into one set" = {
    expr = rules {
      internalTCPPorts = lib.mkMerge [
        [ 22 ]
        [ 3000 ]
      ];
    };
    expected = ''
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport { 22, 3000 } accept
      ip6 saddr { fc00::/7, fe80::/10 } tcp dport { 22, 3000 } accept
    '';
  };
}
