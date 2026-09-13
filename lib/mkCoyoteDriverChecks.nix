{
  pkgs,
  coyoteRoot,
  driverSource ? coyoteRoot,
  driverKernel,
  hostName ? "unknown",
}:
let
  mkDriver = import ./mkCoyoteDriverPackage.nix;
  drivers = builtins.listToAttrs (
    pkgs.lib.concatMap
      (
        targetPlatform:
        map
          (driverVariant: {
            name = "${targetPlatform}-${driverVariant}";
            value = mkDriver {
              inherit
                pkgs
                coyoteRoot
                driverSource
                driverKernel
                hostName
                targetPlatform
                driverVariant
                ;
              pname = "coyote-${hostName}-${targetPlatform}-${driverVariant}";
            };
          })
          [
            "legacy"
            targetPlatform
          ]
      )
      [
        "ultrascale_plus"
        "versal"
      ]
  );
in
{
  inherit drivers;

  namespace =
    pkgs.runCommand "coyote-device-namespace-check"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.stdenv.cc
        ];
      }
      ''
        python3 ${driverSource}/tests/device_namespace_test.py
        touch "$out"
      '';

  modules =
    pkgs.runCommand "coyote-${hostName}-module-identities"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.binutils
        ];
        EXPECTED_KERNEL = driverKernel.modDirVersion;
      }
      ''
        python3 ${driverSource}/tests/driver_variant_test.py \
          ${drivers.ultrascale_plus-legacy} \
          ${drivers.ultrascale_plus-ultrascale_plus} \
          ${drivers.versal-legacy} \
          ${drivers.versal-versal}
        touch "$out"
      '';
}
