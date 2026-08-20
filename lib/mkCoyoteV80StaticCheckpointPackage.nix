{
  pkgs,
  staticPackage,
  pcieGeneration,
  pname ? "coyote-v80-static-checkpoints",
  version ? "0.1.0",
}:

let
  generation = toString pcieGeneration;
  validGeneration = builtins.elem pcieGeneration [
    4
    5
  ];
in
if !validGeneration then
  throw "coyote-nix: V80 static checkpoint PCIe generation must be 4 or 5"
else
  pkgs.runCommand "${pname}-${version}"
    {
      passthru.coyoteV80StaticCheckpoints = {
        schemaVersion = 1;
        board = "v80";
        inherit pcieGeneration;
        sourcePackage = toString staticPackage;
        synthesizedCheckpoint = "checkpoints/static_synthed_v80_gen${generation}.dcp";
        routedCheckpoint = "checkpoints/static_routed_locked_v80_gen${generation}.dcp";
      };
    }
    ''
      mkdir -p "$out"
      cp -r ${staticPackage}/. "$out/"
      chmod -R u+w "$out"
      mkdir -p "$out/checkpoints" "$out/metadata"

      synthesized_source="${staticPackage}/checkpoints/static/static_synthed.dcp"
      if [ ! -f "$synthesized_source" ]; then
        synthesized_source="${staticPackage}/checkpoints/static_synthed_v80_gen${generation}.dcp"
      fi
      routed_source="${staticPackage}/checkpoints/static_routed_locked.dcp"
      if [ ! -f "$routed_source" ]; then
        routed_source="${staticPackage}/checkpoints/static_routed_locked_v80_gen${generation}.dcp"
      fi

      if [ ! -f "$synthesized_source" ]; then
        echo "ERROR: V80 static package lacks its synthesized static checkpoint" >&2
        exit 1
      fi
      if [ ! -f "$routed_source" ]; then
        echo "ERROR: V80 static package lacks its routed locked static checkpoint" >&2
        exit 1
      fi

      install -m0644 "$synthesized_source" \
        "$out/checkpoints/static_synthed_v80_gen${generation}.dcp"
      install -m0644 "$routed_source" \
        "$out/checkpoints/static_routed_locked_v80_gen${generation}.dcp"

      ${pkgs.jq}/bin/jq -n \
        --arg sourcePackage '${toString staticPackage}' \
        --argjson pcieGeneration '${generation}' \
        --arg synthesizedCheckpoint "checkpoints/static_synthed_v80_gen${generation}.dcp" \
        --arg routedCheckpoint "checkpoints/static_routed_locked_v80_gen${generation}.dcp" \
        '{
          schemaVersion: 1,
          board: "v80",
          pcieGeneration: $pcieGeneration,
          sourcePackage: $sourcePackage,
          synthesizedCheckpoint: $synthesizedCheckpoint,
          routedCheckpoint: $routedCheckpoint
        }' > "$out/metadata/v80-static-checkpoints.json"
    ''
