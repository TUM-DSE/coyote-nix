{
  pkgs,
  coyoteRoot,
  driverKernels,
  targetPlatforms,
  hostNames ? builtins.attrNames driverKernels,
  pnamePrefix ? "coyote-driver",
  packageName ? { targetPlatform, hostName }: "${pnamePrefix}-${targetPlatform}-${hostName}",
  version ? "0.1.0",
  extraMakeFlags ? [ ],
  extraAttrs ? { },
}:
let
  mkCoyoteDriverPackage = import ./mkCoyoteDriverPackage.nix;
  resolve = value: combo: if builtins.isFunction value then value combo else value;

  mkPackage =
    hostName: targetPlatform:
    let
      combo = { inherit hostName targetPlatform; };
      pname = packageName combo;
    in
    {
      name = pname;
      value = mkCoyoteDriverPackage {
        inherit
          pkgs
          coyoteRoot
          pname
          targetPlatform
          hostName
          version
          ;
        driverKernel = driverKernels.${hostName};
        extraMakeFlags = resolve extraMakeFlags combo;
        extraAttrs = resolve extraAttrs combo;
      };
    };
in
builtins.listToAttrs (
  pkgs.lib.concatMap (
    hostName: map (targetPlatform: mkPackage hostName targetPlatform) targetPlatforms
  ) hostNames
)
