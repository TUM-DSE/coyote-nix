{
  mkTools = import ./mkTools.nix;
  mkCoyoteHwStagePackage = import ./mkCoyoteHwStagePackage.nix;
  mkCoyoteBoardPackages = import ./mkCoyoteBoardPackages.nix;
  mkCoyoteDriverPackage = import ./mkCoyoteDriverPackage.nix;
  mkCoyoteDevShell = import ./mkCoyoteDevShell.nix;

  mkApp = drv: bin: {
    type = "app";
    program = "${drv}/bin/${bin}";
    meta = (drv.meta or { }) // {
      mainProgram = bin;
    };
  };
}
