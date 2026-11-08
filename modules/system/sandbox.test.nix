# What sandbox.nix makes of the paths each service may write, and when it
# refuses a service.
{ lib, evalModules }:

let
  eval =
    config:
    evalModules [
      ./sandbox.nix
      config
    ];
  sandboxed =
    config:
    lib.getAttrs [
      "ProtectSystem"
      "ProtectHome"
      "ReadWritePaths"
    ] (eval config).systemd.services.app.serviceConfig;
  # Only this module's: a config this small fails some of NixOS's own.
  refusals =
    config:
    map (a: a.message) (
      lib.filter (a: !a.assertion && lib.hasInfix "machine.sandbox" a.message) (eval config).assertions
    );
  user.systemd.services.app.serviceConfig.User = "app";
in
{
  "a sandboxed service: the file system read-only but for its paths, and no home directories" = {
    expr = sandboxed (
      user
      // {
        machine.sandbox.app.writes = [
          "/var/lib/app"
          "-/mnt/share"
        ];
      }
    );
    expected = {
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [
        "/var/lib/app"
        "-/mnt/share"
      ];
    };
  };

  "a service whose own module protects less: still strict" = {
    expr =
      (sandboxed {
        imports = [ user ];
        machine.sandbox.app = { };
        systemd.services.app.serviceConfig.ProtectSystem = "full";
      }).ProtectSystem;
    expected = "strict";
  };

  "a service that needs to read home directories: its module may say so" = {
    expr =
      (sandboxed {
        imports = [ user ];
        machine.sandbox.app = { };
        systemd.services.app.serviceConfig.ProtectHome = "read-only";
      }).ProtectHome;
    expected = "read-only";
  };

  "a service with no user of its own: refused" = {
    expr = refusals { machine.sandbox.app = { }; };
    expected = [
      "app.service runs as root: give it its own user, or set machine.sandbox.app.root and say why."
    ];
  };

  "a service that says it runs as root: let be" = {
    expr = refusals { machine.sandbox.app.root = true; };
    expected = [ ];
  };

  "a service with its own user: let be" = {
    expr = refusals (user // { machine.sandbox.app = { }; });
    expected = [ ];
  };
}
