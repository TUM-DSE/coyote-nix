{
  pkgs,
  tools,
  coyoteRoot,
  hwSource,
  xilinxShell ? null,
  xilinxShareRoot,
  pname,
  version ? "0.1.0",
  platform,
  coyotePlatform,
  xilinxVersion,
  cmakeFlags ? [ ],
  buildCommands ? [ ],
  expectedPaths ? [ ],
  preConfigureSetup ? "",
  preBuildSetup ? "",
  extraInstallPhase ? "",
  description ? "Coyote hardware build stage for ${platform}",
  nativeBuildInputs ? [ ],
  cores ? 8,
  checkTimingLog ? true,
  requiresVitisHls ? true,
  extraAttrs ? { },
}:

let
  checkedRequiresVitisHls =
    if builtins.isBool requiresVitisHls then
      requiresVitisHls
    else
      throw "coyote-nix: requiresVitisHls must be a Boolean";
  xilinxTools = [ tools.vivado ] ++ pkgs.lib.optionals checkedRequiresVitisHls [ tools.vitis_hls ];
in
pkgs.stdenvNoCC.mkDerivation (
  {
    inherit pname version;
    src = hwSource;

    nativeBuildInputs =
      (with pkgs; [
        bash
        coreutils
        findutils
        gnugrep
        gawk
        gnused
        time
        cmake
        gnumake
        gcc
        jq
        (python3.withPackages (ps: [ ps.jinja2 ]))
        pkg-config
        perl
        which
      ])
      ++ xilinxTools
      ++ pkgs.lib.optionals (xilinxShell != null) [ xilinxShell ]
      ++ nativeBuildInputs;

    COYOTE_ROOT = coyoteRoot;
    FDEV_NAME = platform;
    COYOTE_NIX_PLATFORM = coyotePlatform;
    COYOTE_NIX_XILINX_VERSION = xilinxVersion;
    COYOTE_NIX_XILINX_SHARE_ROOT = toString xilinxShareRoot;
    COYOTE_NIX_NCURSES6_LIB = "${pkgs.ncurses6}/lib/libtinfo.so.6";
    COYOTE_NIX_HW_CORES = toString cores;
    COYOTE_NIX_CHECK_TIMING_LOG = if checkTimingLog then "1" else "0";
    COYOTE_NIX_TIME = "${pkgs.time}/bin/time";
    __impureHostDeps = [
      (toString xilinxShareRoot)
    ];
    dontConfigure = true;
    dontFixup = true;

    buildPhase = ''
          runHook preBuild

          export PATH="${pkgs.lib.makeBinPath xilinxTools}:$PATH"

          build_dir="$PWD/.nix-hw-$FDEV_NAME"
          export build_dir
          export HOME="$build_dir/.home"
          mkdir -p "$HOME"
          export TERM="''${TERM:-xterm-256color}"

          pre_configure_setup_script="$TMPDIR/pre-configure-setup.sh"
          cat > "$pre_configure_setup_script" <<'__COYOTE_NIX_PRE_CONFIGURE_SETUP_EOF__'
      ${preConfigureSetup}
      __COYOTE_NIX_PRE_CONFIGURE_SETUP_EOF__
          if [ -s "$pre_configure_setup_script" ]; then
            bash -euo pipefail "$pre_configure_setup_script"
          fi

          pre_build_setup_script="$TMPDIR/pre-build-setup.sh"
          cat > "$pre_build_setup_script" <<'__COYOTE_NIX_PRE_BUILD_SETUP_EOF__'
      ${preBuildSetup}
      __COYOTE_NIX_PRE_BUILD_SETUP_EOF__

          build_commands_script="$TMPDIR/build-commands.sh"
          cat > "$build_commands_script" <<'__COYOTE_NIX_BUILD_COMMANDS_EOF__'
      ${pkgs.lib.concatMapStringsSep "\n" (cmd: cmd) buildCommands}
      __COYOTE_NIX_BUILD_COMMANDS_EOF__

          expected_paths_file="$TMPDIR/expected-paths.txt"
          cat > "$expected_paths_file" <<'__COYOTE_NIX_EXPECTED_PATHS_EOF__'
      ${pkgs.lib.concatMapStringsSep "\n" (path: path) expectedPaths}
      __COYOTE_NIX_EXPECTED_PATHS_EOF__

          cmake_extra_flags=(
            ${pkgs.lib.concatMapStringsSep "\n      " (flag: ''"${flag}"'') cmakeFlags}
          )

          bash ${../nix/tools/run-coyote-hw-stage-build.sh} \
            "$src" \
            "$build_dir" \
            "$pre_build_setup_script" \
            "$build_commands_script" \
            "$expected_paths_file" \
            "''${cmake_extra_flags[@]}"

          runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      if [ -d "$PWD/.nix-hw-$FDEV_NAME" ]; then
        build_dir="$PWD/.nix-hw-$FDEV_NAME"
      else
        build_dir="$PWD"
      fi
      mkdir -p "$out" "$out/logs" "$out/metadata"

      if [ -f "$build_dir/metadata/execution.json" ]; then
        install -m0644 "$build_dir/metadata/execution.json" "$out/metadata/execution.json"
      fi
      if [ -f "$build_dir/metadata/gnu-time.txt" ]; then
        install -m0644 "$build_dir/metadata/gnu-time.txt" "$out/metadata/gnu-time.txt"
      fi
      if [ -f "$build_dir/metadata/primary-tool.json" ]; then
        install -m0644 "$build_dir/metadata/primary-tool.json" "$out/metadata/primary-tool.json"
      fi
      for command_log in command.stdout.log command.stderr.log; do
        if [ -f "$build_dir/logs/$command_log" ]; then
          install -m0644 "$build_dir/logs/$command_log" "$out/logs/$command_log"
        fi
      done

      if [ -f "$build_dir/vivado.log" ]; then
        install -m0644 "$build_dir/vivado.log" "$out/logs/vivado.log"
      fi
      if [ -f "$build_dir/vivado.jou" ]; then
        install -m0644 "$build_dir/vivado.jou" "$out/logs/vivado.jou"
      fi

      ${extraInstallPhase}

      runHook postInstall
    '';

    meta = {
      inherit description;
      platforms = [ "x86_64-linux" ];
    };
  }
  // pkgs.lib.optionalAttrs (xilinxShell != null) {
    COYOTE_NIX_XILINX_SHELL = "${xilinxShell}/bin/xilinx-shell";
  }
  // extraAttrs
)
