# Build the host program of one Coyote example (examples/<directory>/sw)
# together with the Coyote library it links against.
{
  pkgs,
  coyoteRoot,
  name,
  directory,
  # Builds against nixpkgs' ROCm for AMD Instinct GPUs.
  gpu ? false,
  amdGpuTargets ? [ "gfx90a" ],
  # Shell commands run in the Coyote source before building.
  postPatch ? "",
  version ? "0.1.0",
}:
let
  inherit (pkgs) lib rocmPackages;
in
pkgs.stdenv.mkDerivation {
  pname = "coyote-example-${name}-sw";
  inherit version;
  src = coyoteRoot;

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.patchelf
  ];
  buildInputs = [ pkgs.boost ] ++ lib.optional gpu rocmPackages.clr;

  cmakeDir = "../examples/${directory}/sw";
  cmakeFlags = lib.optionals gpu [
    "-DCMAKE_CXX_COMPILER=${rocmPackages.clr}/bin/hipcc"
    "-DAMD_GPU=${lib.concatStringsSep ";" amdGpuTargets}"
    "-DCMAKE_HIP_ARCHITECTURES=${lib.concatStringsSep ";" amdGpuTargets}"
  ];

  # Coyote expects ROCm in one directory with a version file, as in /opt/rocm.
  preConfigure = lib.optionalString gpu ''
    mkdir -p "$TMPDIR/rocm/.info"
    echo ${rocmPackages.clr.version} > "$TMPDIR/rocm/.info/version"
    export ROCM_PATH="$TMPDIR/rocm" HIP_PATH=${rocmPackages.clr}
  '';

  inherit postPatch;

  # The examples have no install target. Their program is called test.
  installPhase = ''
    runHook preInstall
    install -Dm755 test "$out/bin/${name}"
    install -Dm755 coyote/libcoyote.so "$out/lib/libcoyote.so"
    rpath=$(patchelf --print-rpath "$out/bin/${name}" | tr : '\n' | grep -v '^/build/' | paste -sd:)
    patchelf --set-rpath "$out/lib''${rpath:+:$rpath}" "$out/bin/${name}"
    runHook postInstall
  '';

  meta = {
    description = "Host program of Coyote example ${directory}";
    mainProgram = name;
    platforms = [ "x86_64-linux" ];
  };
}
