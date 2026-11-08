# What the service commands module makes of each declared command.
{ lib, evalModules }:

let
  eval =
    commands:
    evalModules [
      ./default.nix
      { machine.serviceCommands = commands; }
    ];
  refusals =
    commands:
    map (a: a.message) (
      lib.filter (a: !a.assertion && lib.hasInfix "machine.serviceCommands" a.message)
        (eval commands).assertions
    );
in
{
  "a service with a unit: its logs are that unit's" = {
    expr = (eval { app.unit = "app.service"; }).machine.serviceCommands.app.journal;
    expected = [ "--unit=app.service" ];
  };

  "a service with no unit: its logs are the journal options it gives" = {
    expr = (eval { app.journal = [ "--identifier=app" ]; }).machine.serviceCommands.app.journal;
    expected = [ "--identifier=app" ];
  };

  "a service with neither: refused" = {
    expr = refusals { app = { }; };
    expected = [ "machine.serviceCommands.app needs a unit or journal options to read its logs by." ];
  };

  "the command: on PATH, ahead of any other program of its name" = {
    expr = map (p: p.meta.priority or null) (
      lib.filter (p: (p.name or "") == "app")
        (eval { app.unit = "app.service"; }).environment.systemPackages
    );
    # lib.hiPrio
    expected = [ (-10) ];
  };
}
