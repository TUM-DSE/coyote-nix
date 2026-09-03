{
  pkgs,
  coyoteRoot,
  coyoteRevision ? null,
  pname,
  targetPlatform,
  driverKernel,
  hostName ? "unknown",
  version ? "0.1.0",
  extraMakeFlags ? [ ],
  extraAttrs ? { },
}:

let
  sourceRevision = import ./resolveCoyoteSourceRevision.nix {
    inherit coyoteRoot coyoteRevision;
  };
in
pkgs.stdenv.mkDerivation (
  {
    inherit pname version;
    src = coyoteRoot + "/driver";

    nativeBuildInputs = driverKernel.moduleBuildDependencies;
    dontConfigure = true;
    dontFixup = true;
    dontStrip = true;
    enableParallelBuilding = true;

    buildPhase = ''
      runHook preBuild
      make TARGET_PLATFORM=${targetPlatform} KERNELDIR=${driverKernel.dev}/lib/modules/${driverKernel.modDirVersion}/build ${pkgs.lib.escapeShellArgs extraMakeFlags} -j "$NIX_BUILD_CORES"
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm0644 build/coyote_driver.ko "$out/lib/modules/${driverKernel.modDirVersion}/extra/coyote_driver.ko"
      ln -s "lib/modules/${driverKernel.modDirVersion}/extra/coyote_driver.ko" "$out/coyote_driver.ko"
      ${pkgs.lib.optionalString (sourceRevision != null) ''
        mkdir -p "$out/metadata"
        printf '%s\n' ${pkgs.lib.escapeShellArg sourceRevision} > "$out/metadata/coyote-source-revision"
      ''}
      runHook postInstall
    '';

    passthru.coyoteDriver = {
      inherit sourceRevision targetPlatform;
      kernelRelease = driverKernel.modDirVersion;
    };

    meta = {
      description = "Coyote kernel driver for ${targetPlatform} built against the ${hostName} host kernel";
      platforms = [ "x86_64-linux" ];
    };
  }
  // extraAttrs
)
