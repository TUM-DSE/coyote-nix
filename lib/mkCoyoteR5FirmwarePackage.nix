{
  pkgs,
  tools,
  pname,
  src,
  platformContract,
  firmwareAbi,
  runtimeIdentity ? null,
  version ? "0.1.0",
  makeTarget ? "all",
  elfPath ? "build/r5.elf",
  mapPath ? "build/r5.map",
  extraMakeFlags ? [ ],
  extraAttrs ? { },
}:
let
  contractApi = platformContract.api or "";
  platformContractId = builtins.hashString "sha256" (builtins.toJSON platformContract);
  contractFile = pkgs.writeText "r5-platform-contract.json" (
    builtins.toJSON (platformContract // { inherit platformContractId; })
  );
  python = pkgs.python3.withPackages (packages: [ packages.pyelftools ]);
  checker = ../nix/tools/check-r5-elf.py;
in
assert contractApi == "coyote.v80-r5-platform/v1";
assert (platformContract.processor or "") == "psv_cortexr5_0";
assert (platformContract.core or "") == "r5-0";
assert (platformContract.xilinxVersion or "") != "";
assert
  (platformContract.bootState or { }) == {
    coldResetRequired = true;
    armExceptions = true;
    littleEndian = true;
    cachesDisabled = true;
    delayedHandoff = true;
    warmRehandoffSupported = false;
    tcmEcc = "platform-managed-unverified";
  };
assert firmwareAbi != "";
assert runtimeIdentity == null || builtins.match "[0-9a-f]{64}" runtimeIdentity != null;
pkgs.stdenvNoCC.mkDerivation (
  {
    inherit pname version src;
    nativeBuildInputs = [
      tools.armr5
      pkgs.gnumake
      pkgs.jq
      python
    ];
    dontConfigure = true;
    dontFixup = true;
    dontStrip = true;
    COYOTE_NIX_XILINX_VERSION = platformContract.xilinxVersion;

    buildPhase = ''
      runHook preBuild
      export CC=armr5-none-eabi-gcc AS=armr5-none-eabi-as AR=armr5-none-eabi-ar
      export LD=armr5-none-eabi-ld NM=armr5-none-eabi-nm OBJCOPY=armr5-none-eabi-objcopy
      export OBJDUMP=armr5-none-eabi-objdump READELF=armr5-none-eabi-readelf SIZE=armr5-none-eabi-size
      make ${makeTarget} ${pkgs.lib.escapeShellArgs extraMakeFlags}
      test -s ${pkgs.lib.escapeShellArg elfPath}
      test -s ${pkgs.lib.escapeShellArg mapPath}
      runHook postBuild
    '';

    checkPhase = ''
      runHook preCheck
      ${python}/bin/python ${checker} --elf ${pkgs.lib.escapeShellArg elfPath} \
        --contract ${contractFile} --output r5-elf-report.json
      armr5-none-eabi-readelf -A ${pkgs.lib.escapeShellArg elfPath} > r5-attributes.txt
      grep -E 'Tag_CPU_arch_profile:[[:space:]]+Realtime' r5-attributes.txt >/dev/null
      grep -E 'Tag_CPU_arch:[[:space:]]+v7' r5-attributes.txt >/dev/null
      runHook postCheck
    '';
    doCheck = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/firmware" "$out/analysis" "$out/metadata"
      cp ${pkgs.lib.escapeShellArg elfPath} "$out/firmware/r5.elf"
      cp ${pkgs.lib.escapeShellArg mapPath} "$out/firmware/r5.map"
      cp ${contractFile} "$out/metadata/platform-contract.json"
      cp r5-elf-report.json "$out/metadata/elf-report.json"
      armr5-none-eabi-readelf -h -l -S -A "$out/firmware/r5.elf" > "$out/analysis/readelf.txt"
      armr5-none-eabi-objdump -d "$out/firmware/r5.elf" > "$out/analysis/disassembly.txt"
      armr5-none-eabi-nm -n "$out/firmware/r5.elf" > "$out/analysis/symbols.txt"
      armr5-none-eabi-size -A "$out/firmware/r5.elf" > "$out/analysis/size.txt"
      elf_sha="$(sha256sum "$out/firmware/r5.elf" | cut -d' ' -f1)"
      firmware_id="$(printf '%s\\0%s\\0%s\\n' 'coyote-nix-r5-firmware-v1' \
        ${pkgs.lib.escapeShellArg firmwareAbi} "$elf_sha" \
        | sha256sum | cut -d' ' -f1)"
      printf '%s\n' "$firmware_id" > "$out/metadata/firmware-id"
      runtime_identity=""
      ${pkgs.lib.optionalString (runtimeIdentity != null) ''
        runtime_identity=${pkgs.lib.escapeShellArg runtimeIdentity}
        printf '%s\n' "$runtime_identity" > "$out/metadata/runtime-identity"
      ''}
      jq -n --arg api 'coyote-nix.r5-firmware/v1' \
        --arg firmwareAbi ${pkgs.lib.escapeShellArg firmwareAbi} \
        --arg platformContractId ${pkgs.lib.escapeShellArg platformContractId} \
        --arg firmwareId "$firmware_id" --arg elfSha256 "$elf_sha" \
        --arg runtimeIdentity "$runtime_identity" \
        '{api:$api, firmwareAbi:$firmwareAbi, platformContractId:$platformContractId,
          firmwareId:$firmwareId, elf:{path:"firmware/r5.elf",sha256:$elfSha256},
          map:"firmware/r5.map", report:"metadata/elf-report.json"}
          + (if $runtimeIdentity == "" then {} else {runtimeIdentity:$runtimeIdentity} end)' \
        > "$out/metadata/firmware.json"
      (cd "$out" && find firmware analysis metadata -type f ! -name artifacts.sha256 -print0 \
        | sort -z | xargs -0 sha256sum) > "$out/metadata/artifacts.sha256"
      runHook postInstall
    '';

    passthru.coyoteR5Firmware = {
      api = "coyote-nix.r5-firmware/v1";
      inherit firmwareAbi platformContract platformContractId runtimeIdentity;
      elf = "firmware/r5.elf";
      map = "firmware/r5.map";
      metadata = "metadata/firmware.json";
    };

    meta = {
      description = "Freestanding TCM-bounded Cortex-R5 firmware package";
      platforms = [ "x86_64-linux" ];
    };
  }
  // extraAttrs
)
