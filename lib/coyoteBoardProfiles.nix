{
  u280 = {
    board = "u280";
    platform = "u280";
    coyotePlatform = "ultrascale";
    targetPlatform = "ultrascale_plus";
    fpgaArchitecture = "ultrascale_plus";
    fpgaPart = "xcu280-fsvh2892-2L-e";
    partHint = "xcu280";
    finalArtifacts = [
      "cyt_top.bit"
      "cyt_top.ltx"
    ];
    finalImage = "cyt_top.bit";
    staticShell = true;

    twoStage = {
      enShellPblock = true;
      shellStageNames = [
        "synth"
        "routed"
        "dynamic"
        "bitgen"
      ];
      shellExpectedBitstreams = [
        "cyt_top.bit"
        "shell_top.bin"
        "config_0/vfpga_c0_0.bin"
      ];
      appExpectedBitstreams = [
        "config_0/vfpga_c0_0.bin"
      ];
      shellPartialExtension = "bin";
      appPartialExtension = "bin";
      supportsShellPartial = true;
    };
  };

  v80 = {
    board = "v80";
    platform = "v80";
    coyotePlatform = "versal";
    targetPlatform = "versal";
    fpgaArchitecture = "versal";
    fpgaPart = "xcv80-lsva4737-2MHP-e-S";
    partHint = "xcv80";
    finalArtifacts = [
      "cyt_top.pdi"
      "cyt_top.ltx"
    ];
    finalImage = "cyt_top.pdi";
    staticShell = false;

    twoStage = {
      # Versal does not support Coyote's nested shell/application DFX flow.
      enShellPblock = false;
      shellStageNames = [
        "synth"
        "dynamic"
        "bitgen"
      ];
      shellExpectedBitstreams = [
        "cyt_top.pdi"
        "config_0/vfpga_c0_0.pdi"
      ];
      appExpectedBitstreams = [
        "config_0/vfpga_c0_0.pdi"
      ];
      shellPartialExtension = null;
      appPartialExtension = "pdi";
      supportsShellPartial = false;
    };
  };
}
