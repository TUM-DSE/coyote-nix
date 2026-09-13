{
  pkgs,
  coyoteRoot,
  driverSource ? coyoteRoot,
  pname,
  targetPlatform,
  driverVariant ? "legacy",
  driverKernel,
  hostName ? "unknown",
  version ? "0.1.0",
  extraMakeFlags ? [ ],
  extraAttrs ? { },
}:
let
  validVariants = [
    "legacy"
    "ultrascale_plus"
    "versal"
  ];
  moduleName =
    if driverVariant == "legacy" then "coyote_driver" else "coyote_driver_${driverVariant}";
  identity = { inherit driverVariant moduleName targetPlatform; };
in
assert pkgs.lib.assertMsg (builtins.elem driverVariant validVariants)
  "driverVariant must be legacy, ultrascale_plus, or versal";
assert pkgs.lib.assertMsg (
  driverVariant == "legacy" || driverVariant == targetPlatform
) "Nonlegacy driverVariant must match targetPlatform";
pkgs.stdenv.mkDerivation (
  {
    inherit pname version;
    src = driverSource + "/driver";

    nativeBuildInputs = driverKernel.moduleBuildDependencies;
    dontConfigure = true;
    dontFixup = true;
    dontStrip = true;
    enableParallelBuilding = true;

    buildPhase = ''
      runHook preBuild
      make ${pkgs.lib.escapeShellArgs extraMakeFlags} TARGET_PLATFORM=${pkgs.lib.escapeShellArg targetPlatform} DRIVER_VARIANT=${pkgs.lib.escapeShellArg driverVariant} KERNELDIR=${driverKernel.dev}/lib/modules/${driverKernel.modDirVersion}/build -j "$NIX_BUILD_CORES"
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm0644 build/${moduleName}.ko "$out/lib/modules/${driverKernel.modDirVersion}/extra/${moduleName}.ko"
      ln -s "lib/modules/${driverKernel.modDirVersion}/extra/${moduleName}.ko" "$out/${moduleName}.ko"
      install -Dm0644 ${pkgs.writeText "coyote-driver-identity.json" (builtins.toJSON identity)} "$out/share/coyote/driver-identity.json"
      runHook postInstall
    '';

    meta = {
      description = "Coyote kernel driver for ${targetPlatform} built against the ${hostName} host kernel";
      platforms = [ "x86_64-linux" ];
    };
  }
  // extraAttrs
  // {
    passthru = (extraAttrs.passthru or { }) // identity;
  }
)
