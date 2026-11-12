# Generate the Verilog of one SpinalHDL kernel the way Coyote's
# comp_spinal.tcl does, but ahead of the Vivado build. sbt downloads its
# dependencies, so this is a fixed-output derivation over the Verilog.
{
  pkgs,
  coyoteRoot,
  # Directory containing the kernel's .scala files.
  kernelSource,
  kernel,
  hash,
}:
pkgs.stdenvNoCC.mkDerivation {
  name = "coyote-spinal-${kernel}-verilog";
  nativeBuildInputs = [
    pkgs.sbt
    pkgs.jdk17_headless
  ];
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" kernel
    cd kernel
    cp ${kernelSource}/*.scala ${coyoteRoot}/scripts/apps/build.sbt .
    chmod u+w ./*
    sbt \
      -Dsbt.global.base="$TMPDIR/sbt" \
      -Dsbt.ivy.home="$TMPDIR/ivy" \
      -Dsbt.boot.directory="$TMPDIR/sbt-boot" \
      -Dcoursier.cache="$TMPDIR/coursier" \
      --warn "runMain ${kernel}Verilog"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp gen/*.v "$out/"
    runHook postInstall
  '';

  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = hash;
}
