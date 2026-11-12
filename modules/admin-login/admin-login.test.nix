# What default.nix adds for Syncthing, SABnzbd and NZBHydra2: a root unit that
# makes and keeps a login in /etc/credstore before the unit that sets it, which
# requires it, imports it as a credential, and sets it as the service's user.
# What the steps do is in admin-login.test.sh.
{ lib, evalModules }:

let
  eval =
    enable:
    evalModules [
      ./default.nix
      {
        services.syncthing.enable = enable;
        services.sabnzbd.enable = enable;
        services.nzbhydra2.enable = enable;
        # As sabnzbd.nix allows it: SABnzbd's unit names its package, which needs unrar.
        nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "unrar";
      }
    ];
  config = eval true;
  services = config.systemd.services;
  # Each command, as which script: "other" for one that isn't this module's.
  steps = map (
    command:
    let
      match = builtins.match "([+]?)/nix/store/[^/]*/bin/(.*)" command;
    in
    if match == null then "other" else lib.concatStrings match
  );

  # The generator for `name`, as root, and what it is ordered against.
  generator = name: {
    inherit (services."${name}-admin-login-generate") before after;
    inherit (services."${name}-admin-login-generate".serviceConfig)
      Type
      ProtectSystem
      ReadWritePaths
      ;
    user = services."${name}-admin-login-generate".serviceConfig.User or "root";
    steps = steps [ services."${name}-admin-login-generate".serviceConfig.ExecStart ];
  };
  generated = name: {
    Type = "oneshot";
    ProtectSystem = "strict";
    ReadWritePaths = [ "/etc/credstore" ];
    user = "root";
    steps = [ "${name}-admin-login-generate" ];
  };
  # How the unit that sets the login gets it.
  consumer = unit: name: {
    requires = lib.elem "${name}-admin-login-generate.service" services.${unit}.requires;
    after = lib.elem "${name}-admin-login-generate.service" services.${unit}.after;
    inherit (services.${unit}.serviceConfig) ImportCredential;
  };
  consumes = name: {
    requires = true;
    after = true;
    ImportCredential = "${name}-admin";
  };
in
{
  "the credential store is root's alone, as systemd's own tmpfiles.d makes it" = {
    expr = lib.getAttrs [
      "mode"
      "user"
      "group"
    ] config.systemd.tmpfiles.settings.credstore."/etc/credstore".d;
    expected = {
      mode = "0700";
      user = "root";
      group = "root";
    };
  };

  "SABnzbd: a login made as root before it starts" = {
    expr = generator "sabnzbd";
    expected = generated "sabnzbd" // {
      before = [ "sabnzbd.service" ];
      after = [ ];
    };
  };

  "SABnzbd: requires it, imports it, and sets it as its user before the module merges sabnzbd.ini" = {
    expr = consumer "sabnzbd" "sabnzbd" // {
      steps = steps services.sabnzbd.serviceConfig.ExecStartPre;
      inherit (services.sabnzbd.serviceConfig) RuntimeDirectory;
      inherit (config.services.sabnzbd) secretFiles;
    };
    expected = consumes "sabnzbd" // {
      steps = [
        "sabnzbd-admin-login"
        # The module's preStart.
        "sabnzbd-pre-start"
      ];
      RuntimeDirectory = "sabnzbd";
      secretFiles = [ "/run/sabnzbd/admin-login.ini" ];
    };
  };

  "NZBHydra2: a login made as root before it starts" = {
    expr = generator "nzbhydra2";
    expected = generated "nzbhydra2" // {
      before = [ "nzbhydra2.service" ];
      after = [ ];
    };
  };

  "NZBHydra2: requires it, imports it, and sets it as its user before it starts" = {
    expr = consumer "nzbhydra2" "nzbhydra2" // {
      steps = steps services.nzbhydra2.serviceConfig.ExecStartPre;
      inherit (services.nzbhydra2.serviceConfig) User;
    };
    expected = consumes "nzbhydra2" // {
      steps = [ "nzbhydra2-admin-login" ];
      User = "nzbhydra2";
    };
  };

  "Syncthing: a login made as root once it has started, before the unit that sets it" = {
    expr = generator "syncthing";
    expected = generated "syncthing" // {
      before = [ "syncthing-admin-login.service" ];
      after = [ "syncthing.service" ];
    };
  };

  "Syncthing: each time it starts, a unit of its own requires and imports it, and sets it as its user" =
    let
      unit = services.syncthing-admin-login;
    in
    {
      expr = consumer "syncthing-admin-login" "syncthing" // {
        inherit (unit) wantedBy;
        syncthing = lib.elem "syncthing.service" unit.requires;
        inherit (unit.serviceConfig) User ProtectSystem ProtectHome;
        steps = steps [ unit.serviceConfig.ExecStart ];
      };
      expected = consumes "syncthing" // {
        wantedBy = [ "syncthing.service" ];
        syncthing = true;
        User = "syncthing";
        ProtectSystem = "strict";
        ProtectHome = true;
        steps = [ "syncthing-admin-login" ];
      };
    };

  "a service that is off: nothing for it" = {
    expr =
      let
        off = eval false;
      in
      lib.filter (unit: off.systemd.services ? ${unit}) [
        "syncthing-admin-login"
        "syncthing-admin-login-generate"
        "sabnzbd"
        "sabnzbd-admin-login-generate"
        "nzbhydra2"
        "nzbhydra2-admin-login-generate"
      ]
      ++ lib.optional (off.systemd.tmpfiles.settings ? credstore) "credstore";
    expected = [ ];
  };
}
