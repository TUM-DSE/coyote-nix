# Parent flake wiring should evaluate this with the exact V80 package arguments used by its slot profile.
# It constructs derivations only; it does not build or launch Vivado.
{ mkCoyoteShellPackage, packageArgs }:
let
  hintsA = {
    groups = [
      {
        name = "queue0";
        cells = [ "inst_shell/qshell/output_queues[0].inst_output_queue" ];
        sites = [ "SLICE_X10Y20" ];
      }
    ];
  };
  hintsB = {
    groups = [
      {
        name = "queue0";
        cells = [ "inst_shell/qshell/output_queues[0].inst_output_queue" ];
        sites = [ "SLICE_X11Y20" ];
      }
    ];
  };
  checkedArgs = packageArgs // {
    implementation = (packageArgs.implementation or { }) // {
      topology = (packageArgs.implementation or { }).topology or {
        configurations = 1;
        regions = 1;
      };
    };
  };
  base = mkCoyoteShellPackage checkedArgs;
  a = mkCoyoteShellPackage (checkedArgs // { placementHints = hintsA; });
  b = mkCoyoteShellPackage (checkedArgs // { placementHints = hintsB; });
  baseStages = base.coyoteTwoStage.stages;
  aStages = a.coyoteTwoStage.stages;
  bStages = b.coyoteTwoStage.stages;
  drv = stage: stage.drvPath;
in
assert a.coyoteTwoStage.physical.placementHints.id != b.coyoteTwoStage.physical.placementHints.id;
assert drv baseStages.residentShellSynthesis == drv aStages.residentShellSynthesis;
assert drv aStages.residentShellSynthesis == drv bStages.residentShellSynthesis;
assert drv baseStages.synth == drv aStages.synth;
assert drv aStages.synth == drv bStages.synth;
assert drv baseStages.implementationInputs == drv aStages.implementationInputs;
assert drv aStages.implementationInputs == drv bStages.implementationInputs;
assert drv baseStages.link == drv aStages.link;
assert drv aStages.link == drv bStages.link;
assert drv baseStages.opt == drv aStages.opt;
assert drv aStages.opt == drv bStages.opt;
assert drv baseStages.place != drv aStages.place;
assert drv aStages.place != drv bStages.place;
assert drv baseStages.route != drv aStages.route;
assert drv aStages.route != drv bStages.route;
assert drv baseStages.validate != drv aStages.validate;
assert drv aStages.validate != drv bStages.validate;
# The shared static checkpoint is a caller-owned input, outside this shell derivation.
assert packageArgs.staticPath == base.coyoteTwoStage.staticPath;
assert base.coyoteTwoStage.staticPath == a.coyoteTwoStage.staticPath;
assert a.coyoteTwoStage.staticPath == b.coyoteTwoStage.staticPath;
{
  api = "coyote-nix.placement-hints-derivation-regression/v1";
  passed = true;
  stages = {
    synthesisShared = drv aStages.residentShellSynthesis == drv bStages.residentShellSynthesis;
    seedSynthesisShared = drv aStages.synth == drv bStages.synth;
    implementationInputsShared = drv aStages.implementationInputs == drv bStages.implementationInputs;
    staticInputShared = a.coyoteTwoStage.staticPath == b.coyoteTwoStage.staticPath;
    linkShared = drv aStages.link == drv bStages.link;
    optShared = drv aStages.opt == drv bStages.opt;
    placeDiffers = drv aStages.place != drv bStages.place;
    routeDiffers = drv aStages.route != drv bStages.route;
    validateDiffers = drv aStages.validate != drv bStages.validate;
  };
}
