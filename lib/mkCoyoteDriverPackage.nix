{
  pkgs,
  coyoteRoot,
  pname,
  targetPlatform,
  driverKernel,
  hostName ? "unknown",
  variant ? "legacy",
  moduleName ? if variant == "legacy" then "coyote_driver" else "coyote_driver_${variant}",
  version ? "0.1.0",
  extraMakeFlags ? [ ],
  extraAttrs ? { },
}:

assert builtins.elem variant [
  "legacy"
  targetPlatform
];
assert moduleName == (if variant == "legacy" then "coyote_driver" else "coyote_driver_${variant}");
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
      make DRIVER_VARIANT=${variant} TARGET_PLATFORM=${targetPlatform} KERNELDIR=${driverKernel.dev}/lib/modules/${driverKernel.modDirVersion}/build ${pkgs.lib.escapeShellArgs extraMakeFlags} -j "$NIX_BUILD_CORES"
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm0644 build/${moduleName}.ko "$out/lib/modules/${driverKernel.modDirVersion}/extra/${moduleName}.ko"
      ln -s "lib/modules/${driverKernel.modDirVersion}/extra/${moduleName}.ko" "$out/${moduleName}.ko"
      install -Dm0644 ${driverKernel.dev}/lib/modules/${driverKernel.modDirVersion}/build/.config "$out/kernel.config"
      printf '%s\n' '${driverKernel}' > "$out/kernel-store-path"
      printf '%s\n' '${moduleName}' > "$out/module-name"
      runHook postInstall
    '';

    passthru = { inherit moduleName variant driverKernel; };

    meta = {
      description = "Coyote kernel driver for ${targetPlatform} built against the ${hostName} host kernel";
      platforms = [ "x86_64-linux" ];
    };
  }
  // extraAttrs
)
