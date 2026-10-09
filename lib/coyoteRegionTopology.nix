# Immutable shell staging covers one complete configuration and its physical regions.
{
  lib,
  topology ? {
    configurations = 1;
    regions = 1;
  },
}:
let
  checked =
    if
      !builtins.isAttrs topology
      ||
        builtins.attrNames topology != [
          "configurations"
          "regions"
        ]
      || !builtins.isInt topology.configurations
      || topology.configurations != 1
      || !builtins.isInt topology.regions
      || topology.regions < 1
      || topology.regions > 15
    then
      throw "coyote-nix: shell topology requires one configuration and 1..15 regions"
    else
      topology;
  physicalRegions = builtins.genList (region: {
    inherit region;
    cell = "inst_shell/inst_dynamic/inst_user_wrapper_${toString region}";
    seedCheckpoint = "checkpoints/config_0/user_synthed_c0_${toString region}.dcp";
  }) checked.regions;
in
{
  topology = checked;
  inherit physicalRegions;
  seedPaths = map (entry: entry.seedCheckpoint) physicalRegions;
  seedArtifacts = map (entry: {
    role =
      if entry.region == 0 then
        "seed-synthesized-checkpoint"
      else
        "seed-synthesized-checkpoint-region-${toString entry.region}";
    path = entry.seedCheckpoint;
  }) physicalRegions;
}
