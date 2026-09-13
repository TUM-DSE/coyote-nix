{ pkgs }:
let
  mkPackage = import ../lib/mkCoyoteDriverPackage.nix;
  mkPackages = import ../lib/mkCoyoteDriverPackages.nix;
  # A tiny producer exercises the packaging contract without compiling a kernel.
  driverSource = pkgs.runCommand "driver-package-test-source" { } ''
    mkdir -p "$out/driver"
    cat > "$out/driver/Makefile" <<'EOF'
    DRIVER_VARIANT ?= legacy
    MODULE = $(if $(filter legacy,$(DRIVER_VARIANT)),coyote_driver,coyote_driver_$(DRIVER_VARIANT))
    all:
    	mkdir -p build
    	printf '%s\n' '$(TARGET_PLATFORM)' '$(DRIVER_VARIANT)' > build/$(MODULE).ko
    EOF
  '';
  kernel = {
    moduleBuildDependencies = [ ];
    dev = "/unused-test-kernel";
    modDirVersion = "test-kernel";
  };
  common = {
    inherit pkgs driverSource;
    # Only driverSource may supply the module sources.
    coyoteRoot = "/not-the-driver-source";
  };
  packageArgs = common // {
    pname = "driver-package-test";
    targetPlatform = "ultrascale_plus";
    driverKernel = kernel;
  };
  legacy = mkPackage packageArgs;
  isolated = mkPackages (
    common
    // {
      driverKernels.test = kernel;
      targetPlatforms = [
        "ultrascale_plus"
        "versal"
      ];
      driverVariant = combo: combo.targetPlatform;
      extraAttrs.passthru.custom = "preserved";
    }
  );
  constant = mkPackages (
    common
    // {
      driverKernels.test = kernel;
      targetPlatforms = [ "versal" ];
      driverVariant = "versal";
    }
  );
  rejected = attrs: !(builtins.tryEval (mkPackage (packageArgs // attrs)).drvPath).success;
  cases = [
    {
      package = legacy;
      platform = "ultrascale_plus";
      variant = "legacy";
      module = "coyote_driver";
    }
    {
      package = isolated.coyote-driver-ultrascale_plus-test;
      platform = "ultrascale_plus";
      variant = "ultrascale_plus";
      module = "coyote_driver_ultrascale_plus";
    }
    {
      package = isolated.coyote-driver-versal-test;
      platform = "versal";
      variant = "versal";
      module = "coyote_driver_versal";
    }
  ];
in
assert rejected { driverVariant = "invalid"; };
assert rejected { driverVariant = "versal"; };
assert rejected {
  driverVariant = "ultrascale_plus";
  targetPlatform = "versal";
};
assert constant.coyote-driver-versal-test.driverVariant == "versal";
assert isolated.coyote-driver-versal-test.custom == "preserved";
pkgs.runCommand "driver-package-variants-check" { nativeBuildInputs = [ pkgs.jq ]; } (
  pkgs.lib.concatMapStringsSep "\n" (case: ''
    module=${case.module}
    test -L ${case.package}/"$module.ko"
    cmp ${case.package}/"$module.ko" ${case.package}/lib/modules/test-kernel/extra/"$module.ko"
    printf '%s\n' '${case.platform}' '${case.variant}' > expected
    cmp expected ${case.package}/"$module.ko"
    jq -e --arg module "$module" --arg variant '${case.variant}' --arg platform '${case.platform}' \
      '.moduleName == $module and .driverVariant == $variant and .targetPlatform == $platform' \
      ${case.package}/share/coyote/driver-identity.json
  '') cases
  + ''
    touch "$out"
  ''
)
