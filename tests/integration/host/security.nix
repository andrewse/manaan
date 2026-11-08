# What a host lets in, and what its services may do once in.
{ lib, config }:

let
  services = config.systemd.services;
  sandbox = config.machine.sandbox;
  firewall = config.networking.firewall;
  internal = config.machine.firewall.internalTCPPorts;
  opened = port: {
    public = lib.elem port firewall.allowedTCPPorts;
    internal = lib.elem port internal;
  };
  ssh = config.services.openssh;
  git = config.machine.gitServer;
  prometheus = config.services.prometheus;
  grafana = config.services.grafana;

  confined = lib.filterAttrs (_: unit: !unit.root) sandbox;
  user = unit: services.${unit}.serviceConfig.User or "root";
  dynamic = unit: services.${unit}.serviceConfig.DynamicUser or false;
in
{
  "every assertion the host's modules make holds" = {
    expr = map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);
    expected = [ ];
  };

  "each sandboxed service is one the host runs" = {
    expr = lib.attrNames (
      lib.filterAttrs (
        unit: _: !(services.${unit}.serviceConfig ? ExecStart || services.${unit}.script != "")
      ) sandbox
    );
    expected = [ ];
  };

  "each sandboxed service sees the file system read-only but for its own paths" = {
    expr = lib.attrNames (
      lib.filterAttrs (
        unit: s:
        let
          sc = services.${unit}.serviceConfig;
        in
        sc.ProtectSystem != "strict" || !lib.all (path: lib.elem path sc.ReadWritePaths) s.writes
      ) sandbox
    );
    expected = [ ];
  };

  "each sandboxed service runs as a user of its own, unless it says why not" = {
    expr = {
      root = lib.attrNames (lib.filterAttrs (unit: _: user unit == "root" && !dynamic unit) confined);
      shared = lib.filterAttrs (_: units: lib.length units > 1) (
        lib.groupBy user (lib.filter (unit: !dynamic unit) (lib.attrNames confined))
      );
    };
    expected = {
      root = [ ];
      shared = { };
    };
  };

  "SSH: from private networks only, by key only, and never as root" = {
    expr = {
      ports = map opened ssh.ports;
      inherit (ssh) openFirewall;
      inherit (ssh.settings) PermitRootLogin PasswordAuthentication KbdInteractiveAuthentication;
    };
    expected = {
      ports = map (_: {
        public = false;
        internal = true;
      }) ssh.ports;
      openFirewall = false;
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
}
// lib.optionalAttrs git.enable {
  "the git user gets the wrapper and nothing else, without a terminal" = {
    expr = map (line: lib.hasInfix line ssh.extraConfig) [
      "Match User git"
      "ForceCommand /nix/store/"
      "PermitTTY no"
    ];
    expected = [
      true
      true
      true
    ];
  };

  "every admin's key can push, and do nothing else over SSH" = {
    expr = lib.sort lib.lessThan config.users.users.git.openssh.authorizedKeys.keys;
    expected = lib.sort lib.lessThan (
      map (key: "restrict ${key}") (lib.concatLists (lib.attrValues config.machine.users))
    );
  };

  "a repo the wrapper creates has main as its HEAD, as pushed" = {
    expr = lib.any (c: (c.init.defaultBranch or null) == "main") (
      lib.toList config.programs.git.config
    );
    expected = true;
  };
}
// lib.optionalAttrs prometheus.enable {
  "the metrics are reachable only on the machine itself" = {
    expr = {
      inherit (prometheus) listenAddress;
      ports = map opened (
        [ prometheus.port ]
        ++ lib.optional prometheus.exporters.node.enable prometheus.exporters.node.port
        ++ lib.optional config.services.cadvisor.enable config.services.cadvisor.port
      );
    };
    expected = {
      listenAddress = "127.0.0.1";
      ports =
        map
          (_: {
            public = false;
            internal = false;
          })
          (
            [ prometheus.port ]
            ++ lib.optional prometheus.exporters.node.enable prometheus.exporters.node.port
            ++ lib.optional config.services.cadvisor.enable config.services.cadvisor.port
          );
    };
  };
}
// lib.optionalAttrs config.services.sabnzbd.enable {
  "SABnzbd gets a /tmp of its own, as the sandbox leaves the host's read-only" = {
    expr = services.sabnzbd.serviceConfig.PrivateTmp or false;
    expected = true;
  };
}
// lib.optionalAttrs grafana.enable {
  "Grafana is reachable from private networks only" = {
    expr = opened grafana.settings.server.http_port;
    expected = {
      public = false;
      internal = true;
    };
  };
}
