{
  pkgs,
  tools,
  pname,
  platformPackage,
  firmwarePackage,
  version ? "0.1.0",
  extraAttrs ? { },
}:
let
  platform = platformPackage.coyoteR5Platform or { };
  firmware = firmwarePackage.coyoteR5Firmware or { };
  policyTool = ../nix/tools/versal-r5-bif.py;
  platformApi = platform.api or "";
  firmwareApi = firmware.api or "";
  platformContractId = platform.platformContractId or "";
  firmwarePlatformContractId = firmware.platformContractId or "";
  subsystemId = platform.subsystemId or "";
  xilinxVersion = platform.xilinxVersion or "";
  safeRelative =
    value:
    builtins.isString value
    && builtins.match "[A-Za-z0-9][A-Za-z0-9._/-]*" value != null
    && !(pkgs.lib.hasInfix ".." value)
    && !(pkgs.lib.hasInfix "//" value)
    && !(pkgs.lib.hasInfix "/./" value);
in
assert platformApi == "coyote-nix.v80-r5-platform/v1";
assert firmwareApi == "coyote-nix.r5-firmware/v1";
assert (platform.platformId or "") != "";
assert xilinxVersion != "";
assert subsystemId == "0x1c000000";
assert safeRelative (platform.basePdi or "");
assert safeRelative (platform.metadata or "");
assert safeRelative (platform.contract or "");
assert safeRelative (firmware.elf or "");
assert safeRelative (firmware.metadata or "");
assert platformContractId != "" && platformContractId == firmwarePlatformContractId;
pkgs.stdenvNoCC.mkDerivation (
  {
    inherit pname version;
    dontUnpack = true;
    nativeBuildInputs = [
      tools.bootgen
      tools.r5-elf-check
      pkgs.jq
      pkgs.python3
    ];
    dontFixup = true;
    COYOTE_NIX_XILINX_VERSION = xilinxVersion;

    buildPhase = ''
      runHook preBuild
      mkdir -p composition bitstreams metadata
      cp ${pkgs.lib.escapeShellArg "${platformPackage}/${platform.basePdi}"} composition/platform-base.pdi
      cp ${pkgs.lib.escapeShellArg "${platformPackage}/${platform.metadata}"} composition/platform.json
      cp ${pkgs.lib.escapeShellArg "${platformPackage}/${platform.contract}"} composition/platform-contract.json
      cp ${pkgs.lib.escapeShellArg "${firmwarePackage}/${firmware.elf}"} composition/firmware.elf
      cp ${pkgs.lib.escapeShellArg "${firmwarePackage}/${firmware.metadata}"} composition/firmware.json
      cp ${firmwarePackage}/metadata/platform-contract.json composition/firmware-platform-contract.json
      cmp composition/platform-contract.json composition/firmware-platform-contract.json
      test "$(jq -r .platformContractId composition/platform-contract.json)" = \
        ${pkgs.lib.escapeShellArg platformContractId}

      test "$(jq -r .api composition/platform.json)" = 'coyote-nix.v80-r5-platform/v1'
      test "$(jq -r .platformId composition/platform.json)" = ${pkgs.lib.escapeShellArg platform.platformId}
      test "$(jq -r .platformContractId composition/platform.json)" = ${pkgs.lib.escapeShellArg platformContractId}
      test "$(jq -r .xilinxVersion composition/platform.json)" = ${pkgs.lib.escapeShellArg xilinxVersion}
      test "$(jq -r .subsystemId composition/platform.json)" = '0x1c000000'
      test "$(jq -r .basePdi.path composition/platform.json)" = ${pkgs.lib.escapeShellArg platform.basePdi}
      test "$(sha256sum composition/platform-base.pdi | cut -d' ' -f1)" = \
        "$(jq -r .basePdi.sha256 composition/platform.json)"

      test "$(jq -r .api composition/firmware.json)" = 'coyote-nix.r5-firmware/v1'
      test "$(jq -r .firmwareAbi composition/firmware.json)" = ${pkgs.lib.escapeShellArg firmware.firmwareAbi}
      test "$(jq -r .platformContractId composition/firmware.json)" = ${pkgs.lib.escapeShellArg platformContractId}
      test "$(jq -r .firmwareId composition/firmware.json)" = \
        "$(cat ${firmwarePackage}/metadata/firmware-id)"
      test "$(jq -r .elf.path composition/firmware.json)" = ${pkgs.lib.escapeShellArg firmware.elf}
      test "$(sha256sum composition/firmware.elf | cut -d' ' -f1)" = \
        "$(jq -r .elf.sha256 composition/firmware.json)"
      expected_firmware_id="$(printf '%s\\0%s\\0%s\\n' 'coyote-nix-r5-firmware-v1' \
        ${pkgs.lib.escapeShellArg firmware.firmwareAbi} \
        "$(jq -r .elf.sha256 composition/firmware.json)" | sha256sum | cut -d' ' -f1)"
      test "$expected_firmware_id" = "$(cat ${firmwarePackage}/metadata/firmware-id)"
      coyote-r5-elf-check --elf composition/firmware.elf \
        --contract composition/platform-contract.json >/dev/null
      python3 ${policyTool} --output composition/deployment.bif \
        --base-pdi platform-base.pdi --firmware-elf firmware.elf \
        --subsystem-id ${pkgs.lib.escapeShellArg subsystemId}
      python3 ${policyTool} --check composition/deployment.bif \
        --base-pdi platform-base.pdi --firmware-elf firmware.elf \
        --subsystem-id ${pkgs.lib.escapeShellArg subsystemId}
      (cd composition && bootgen -arch versal -image deployment.bif -w \
        -o ../bitstreams/cyt_top.pdi)
      test -s bitstreams/cyt_top.pdi
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/composition" "$out/bitstreams" "$out/metadata"
      cp composition/platform-base.pdi composition/platform.json \
        composition/firmware.elf composition/firmware.json \
        composition/platform-contract.json composition/deployment.bif "$out/composition/"
      cp bitstreams/cyt_top.pdi "$out/bitstreams/"
      cp composition/platform.json "$out/metadata/platform.json"
      cp composition/firmware.json "$out/metadata/firmware.json"
      cp composition/platform-contract.json "$out/metadata/platform-contract.json"
      base_sha="$(sha256sum "$out/composition/platform-base.pdi" | cut -d' ' -f1)"
      firmware_sha="$(sha256sum "$out/composition/firmware.elf" | cut -d' ' -f1)"
      bif_sha="$(sha256sum "$out/composition/deployment.bif" | cut -d' ' -f1)"
      pdi_sha="$(sha256sum "$out/bitstreams/cyt_top.pdi" | cut -d' ' -f1)"
      deployment_id="$(printf '%s\\0%s\\0%s\\0%s\\0%s\\0%s\\n' \
        'coyote-nix-r5-deployment-v1' ${pkgs.lib.escapeShellArg platform.platformId} \
        "$(cat ${firmwarePackage}/metadata/firmware-id)" "$base_sha" "$bif_sha" "$pdi_sha" \
        | sha256sum | cut -d' ' -f1)"
      printf '%s\n' "$deployment_id" > "$out/metadata/deployment-id"
      jq -n --arg api 'coyote-nix.r5-deployment/v1' \
        --arg platformId ${pkgs.lib.escapeShellArg platform.platformId} \
        --arg firmwareId "$(cat ${firmwarePackage}/metadata/firmware-id)" \
        --arg deploymentId "$deployment_id" --arg subsystemId ${pkgs.lib.escapeShellArg subsystemId} \
        --arg platformContractId ${pkgs.lib.escapeShellArg platformContractId} \
        --arg xilinxVersion ${pkgs.lib.escapeShellArg xilinxVersion} \
        --arg baseSha256 "$base_sha" --arg firmwareSha256 "$firmware_sha" \
        --arg bifSha256 "$bif_sha" --arg pdiSha256 "$pdi_sha" \
        '{api:$api, platformId:$platformId, platformContractId:$platformContractId,
          firmwareId:$firmwareId, deploymentId:$deploymentId, xilinxVersion:$xilinxVersion,
          policy:{core:"r5-0",delayHandoff:true,subsystemId:$subsystemId},
          artifacts:{basePdiSha256:$baseSha256,firmwareElfSha256:$firmwareSha256,
          bifSha256:$bifSha256,pdiSha256:$pdiSha256}}' > "$out/metadata/deployment.json"
      (cd "$out" && find composition bitstreams metadata -type f ! -name artifacts.sha256 -print0 \
        | sort -z | xargs -0 sha256sum) > "$out/metadata/artifacts.sha256"
      runHook postInstall
    '';

    passthru.coyoteR5Deployment = {
      api = "coyote-nix.r5-deployment/v1";
      inherit subsystemId;
      core = "r5-0";
      delayHandoff = true;
      platformId = platform.platformId;
      platformContractId = platform.platformContractId;
      firmwareAbi = firmware.firmwareAbi;
      pdi = "bitstreams/cyt_top.pdi";
      bif = "composition/deployment.bif";
      metadata = "metadata/deployment.json";
    };

    meta = {
      description = "Checked Versal base-PDI plus delayed-handoff R5 deployment";
      platforms = [ "x86_64-linux" ];
    };
  }
  // extraAttrs
)
