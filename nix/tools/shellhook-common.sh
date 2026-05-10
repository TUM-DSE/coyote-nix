export COYOTE_ROOT="@COYOTE_ROOT@"

project_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
build_root="${COYOTE_NIX_BUILD_ROOT:-$project_root/.build}"

if [ -f "$project_root/sw/CMakeLists.txt" ] && [ "${COYOTE_NIX_SKIP_AUTO_SW_CONFIGURE:-0}" != "1" ]; then
  sw_dir="$project_root/sw"
  build_dir="$build_root/sw"
  db_path="$build_dir/compile_commands.json"
  stamp_path="$build_dir/.coyote_nix-config-fingerprint"
  en_sim_cmake="OFF"

  if [ "${EN_SIM:-0}" = "1" ]; then
    en_sim_cmake="ON"
  fi

  mkdir -p "$build_dir"

  cmake_version="$(cmake --version | head -n1)"
  arch="$(uname -m)"

  fingerprint="$({
    echo "build_dir=$build_dir"
    echo "cmake=$cmake_version"
    echo "arch=$arch"
    echo "en_sim=${EN_SIM:-0}"
    echo "extra_flags=${CMAKE_EXTRA_FLAGS:-}"
    echo "coyote_root=$COYOTE_ROOT"
    [ -f "$project_root/flake.lock" ] && sha256sum "$project_root/flake.lock"
    [ -f "$sw_dir/CMakeLists.txt" ] && sha256sum "$sw_dir/CMakeLists.txt"
    [ -f "$sw_dir/CMakePresets.json" ] && sha256sum "$sw_dir/CMakePresets.json"
  } | sha256sum | awk '{print $1}')"

  old_fingerprint=""
  if [ -f "$stamp_path" ]; then
    old_fingerprint="$(cat "$stamp_path")"
  fi

  if [ ! -f "$db_path" ] || [ "$fingerprint" != "$old_fingerprint" ]; then
    (
      if ! cmake -S "$sw_dir" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.10 \
        -DEN_SIM="$en_sim_cmake" \
        -DCMAKE_POLICY_DEFAULT_CMP0167=OLD >/dev/null; then
        rm -rf "$build_dir"
        mkdir -p "$build_dir"
        cmake -S "$sw_dir" -B "$build_dir" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
          -DCMAKE_POLICY_VERSION_MINIMUM=3.10 \
          -DEN_SIM="$en_sim_cmake" \
          -DCMAKE_POLICY_DEFAULT_CMP0167=OLD >/dev/null
      fi
    )
    printf '%s\n' "$fingerprint" > "$stamp_path"
  fi

  ln -sf "$db_path" "$project_root/compile_commands.json"
fi

if [ "${COYOTE_NIX_SKIP_AUTO_VERIBLE_FILELIST:-0}" != "1" ]; then
  verible_script="$project_root/scripts/gen-verible-filelist.sh"
  verible_filelist="$project_root/verible.filelist"
  verible_cache_dir="$project_root/.cache"
  verible_stamp="$verible_cache_dir/.coyote_nix-verible-filelist-fingerprint"

  if [ -x "$verible_script" ]; then
    mkdir -p "$verible_cache_dir"

    verible_fingerprint="$({
      if git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$project_root" ls-files '*.sv' '*.svh' '*.v' '*.vh' | sort -u
      else
        find "$project_root" -type f \( -name '*.sv' -o -name '*.svh' -o -name '*.v' -o -name '*.vh' \) \
          | sed "s#^$project_root/##" \
          | sort -u
      fi
    } | sha256sum | awk '{print $1}')"

    old_verible_fingerprint=""
    if [ -f "$verible_stamp" ]; then
      old_verible_fingerprint="$(cat "$verible_stamp")"
    fi

    if [ ! -f "$verible_filelist" ] || [ "$verible_fingerprint" != "$old_verible_fingerprint" ]; then
      "$verible_script" "$verible_filelist"
      printf '%s\n' "$verible_fingerprint" > "$verible_stamp"
    fi
  fi
fi
