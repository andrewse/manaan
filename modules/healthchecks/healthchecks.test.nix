# What the healthchecks module makes of the checks and services modules
# declare: how long the healthchecks may take, and how a service's health
# becomes a check.
{ lib, evalModules }:

let
  eval =
    config:
    evalModules [
      ./default.nix
      # notify.nix's, standing in for it: no notifications.
      { options.machine.notify.onFailure = lib.mkOption { default = [ ]; }; }
      config
    ];
  timeout = config: (eval config).systemd.services.healthcheck.serviceConfig.TimeoutStartSec;
  app = {
    machine.healthchecks.services.app = {
      url = "http://127.0.0.1:8000/ping";
      startTimeout = 120;
    };
  };
in
{
  "the healthchecks wait for the default timeout, then a minute more" = {
    expr = timeout {
      machine.healthchecks.checks.port = {
        type = "tcp";
        target = "127.0.0.1:22";
      };
    };
    expected = 360;
  };

  "a check with a longer timeout of its own: they wait for that one" = {
    expr = timeout {
      machine.healthchecks.checks.slow = {
        type = "command";
        target = "true";
        timeout = 600;
      };
    };
    expected = 660;
  };

  "a check that is switched off: not waited for" = {
    expr = timeout {
      machine.healthchecks.checks.slow = {
        type = "command";
        target = "true";
        timeout = 600;
        enable = false;
      };
    };
    expected = 360;
  };

  "a service: a unit check, given a minute longer than the service may take to start" = {
    expr = (eval app).machine.healthchecks.checks.app;
    expected = {
      enable = true;
      type = "unit";
      target = "app.service";
      timeout = 180;
    };
  };

  "a service: held in activating until its URL answers, for as long as it may take to start" = {
    expr =
      let
        service = (eval app).systemd.services.app.serviceConfig;
      in
      {
        waits = map (lib.hasSuffix ''/bin/wait-healthy" "http://127.0.0.1:8000/ping"'') service.ExecStartPost;
        inherit (service) TimeoutStartSec;
      };
    expected = {
      waits = [ true ];
      TimeoutStartSec = 120;
    };
  };

  "the healthchecks start after the network is up, on every boot" = {
    expr = lib.getAttrs [ "wants" "after" "wantedBy" ] (eval { }).systemd.services.healthcheck;
    expected = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
    };
  };
}
