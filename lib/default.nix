{
  mkTools = import ./mkTools.nix;
  mkCoyoteHwStagePackage = import ./mkCoyoteHwStagePackage.nix;
  mkCoyoteBoardPackages = import ./mkCoyoteBoardPackages.nix;
  mkCoyoteShellPackage = import ./mkCoyoteShellPackage.nix;
  mkCoyoteAppPackage = import ./mkCoyoteAppPackage.nix;
  mkCoyoteDriverPackage = import ./mkCoyoteDriverPackage.nix;
  mkCoyoteDriverPackages = import ./mkCoyoteDriverPackages.nix;
  mkCoyoteDevShell = import ./mkCoyoteDevShell.nix;
  mkCoyoteSourceChecks = import ./mkCoyoteSourceChecks.nix;
  mkCoyoteR5FirmwarePackage = import ./mkCoyoteR5FirmwarePackage.nix;
  mkCoyoteR5BootPackage = import ./mkCoyoteR5BootPackage.nix;

  mkApp = drv: bin: {
    type = "app";
    program = "${drv}/bin/${bin}";
    meta = (drv.meta or { }) // {
      mainProgram = bin;
    };
  };
}
