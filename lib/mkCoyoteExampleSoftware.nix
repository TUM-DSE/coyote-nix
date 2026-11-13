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

  # Coyote expects ROCm in one directory, as in /opt/rocm: HIP, the HSA
  # runtime and its include/hsa headers, ROCm SMI and a version file.
  rocm = pkgs.symlinkJoin {
    name = "coyote-rocm-${rocmPackages.clr.version}";
    paths = with rocmPackages; [
      clr
      rocm-runtime
      rocm-smi
    ];
    postBuild = ''
      rm -rf "$out/.info"
      mkdir "$out/.info"
      echo ${rocmPackages.clr.version} > "$out/.info/version"
    '';
  };
in
pkgs.stdenv.mkDerivation {
  pname = "coyote-example-${name}-sw";
  inherit version;
  src = coyoteRoot;

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.patchelf
  ];
  buildInputs = [
    pkgs.boost
  ]
  ++ lib.optionals gpu [
    rocm
    pkgs.numactl
    pkgs.libdrm
  ];

  cmakeDir = "../examples/${directory}/sw";
  cmakeFlags = lib.optionals gpu [
    # Older Coyote names the ROCm backend EN_GPU, newer EN_ROCM; each ignores
    # the other.
    "-DEN_GPU=1"
    "-DEN_ROCM=1"
    "-DCMAKE_CXX_COMPILER=${rocmPackages.clr}/bin/hipcc"
    "-DAMD_GPU=${lib.concatStringsSep ";" amdGpuTargets}"
    "-DCMAKE_HIP_ARCHITECTURES=${lib.concatStringsSep ";" amdGpuTargets}"
    # Newer examples no longer pass the GPU targets to hipcc themselves.
    "-DCMAKE_CXX_FLAGS=${lib.concatMapStringsSep " " (t: "--offload-arch=${t}") amdGpuTargets}"
  ];

  preConfigure = lib.optionalString gpu ''
    export ROCM_PATH=${rocm} HIP_PATH=${rocmPackages.clr}
  '';

  inherit postPatch;

  # The examples have no install target. Their program is called test.
  installPhase = ''
    runHook preInstall
    install -Dm755 test "$out/bin/${name}"
    # Some host programs access the card directly, without Coyote's library.
    if [ -e coyote/libcoyote.so ]; then
      install -Dm755 coyote/libcoyote.so "$out/lib/libcoyote.so"
      rpath=$(patchelf --print-rpath "$out/bin/${name}" | tr : '\n' | grep -v '^/build/' | paste -sd:)
      patchelf --set-rpath "$out/lib''${rpath:+:$rpath}" "$out/bin/${name}"
    fi
    runHook postInstall
  '';

  meta = {
    description = "Host program of Coyote example ${directory}";
    mainProgram = name;
    platforms = [ "x86_64-linux" ];
  };
}
