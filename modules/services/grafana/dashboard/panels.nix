# Panel builders for the dashboard. Panels are in reading order; `x`, `y`,
# `w`, `h` place them on the 24-column grid.
{ lib }:

let
  datasource = {
    type = "prometheus";
    uid = "prometheus";
  };

  panel =
    {
      type,
      title,
      x,
      y,
      w,
      h,
      targets ? [ ],
      unit ? null,
      min ? null,
      max ? null,
      thresholds ? null,
      mappings ? [ ],
      custom ? { },
      options ? { },
    }:
    {
      inherit type title options;
      inherit datasource;
      gridPos = {
        inherit
          x
          y
          w
          h
          ;
      };
      targets = lib.imap0 (
        i: t:
        {
          inherit datasource;
          refId = lib.elemAt lib.upperChars i;
        }
        // t
      ) targets;
      fieldConfig = {
        defaults = {
          inherit mappings custom;
        }
        // lib.filterAttrs (_: v: v != null) {
          inherit unit min max;
          thresholds = lib.mapNullable (steps: {
            mode = "absolute";
            steps = lib.imap0 (i: s: {
              color = s.color;
              value = if i == 0 then null else s.value;
            }) steps;
          }) thresholds;
        };
        overrides = [ ];
      };
    };

  row = title: y: {
    type = "row";
    inherit title;
    collapsed = false;
    gridPos = {
      x = 0;
      inherit y;
      w = 24;
      h = 1;
    };
    panels = [ ];
  };

  stat =
    args:
    panel (
      {
        type = "stat";
        options = {
          colorMode = "value";
          graphMode = "area";
          reduceOptions.calcs = [ "lastNotNull" ];
        };
      }
      // args
    );

  timeseries =
    args:
    panel (
      lib.recursiveUpdate {
        type = "timeseries";
        custom = {
          fillOpacity = 10;
          showPoints = "never";
        };
        options = {
          tooltip = {
            mode = "multi";
            sort = "desc";
          };
          legend = {
            displayMode = "table";
            placement = "right";
            calcs = [
              "mean"
              "max"
            ];
            sortBy = "Max";
            sortDesc = true;
          };
        };
      } args
    );

  q = expr: legendFormat: { inherit expr legendFormat; };

  usage = [
    {
      color = "green";
    }
    {
      color = "orange";
      value = 75;
    }
    {
      color = "red";
      value = 90;
    }
  ];
in
{
  inherit
    panel
    row
    stat
    timeseries
    q
    usage
    ;
}
