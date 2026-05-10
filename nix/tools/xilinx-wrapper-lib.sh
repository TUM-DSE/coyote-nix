# Shared helpers for Xilinx shells and tool wrappers.

coyote_nix_default_xilinx_share_root="@XILINX_SHARE_ROOT@"
coyote_nix_default_ncurses6_lib="@NCURSES6_LIB@"

coyote_nix_shell_quote() {
  printf '%q' "$1"
}

coyote_nix_xilinx_share_root() {
  printf '%s\n' "$coyote_nix_default_xilinx_share_root"
}

coyote_nix_xilinx_versions() {
  if [ -n "${COYOTE_NIX_XILINX_VERSION:-}" ]; then
    printf '%s\n' "$COYOTE_NIX_XILINX_VERSION"
    return 0
  fi

  # Compatibility fallback when shell policy did not set a version.
  printf '%s\n' 2023.2 2025.1
}

coyote_nix_resolve_vivado_root_by_version() {
  local root v p

  v="$1"
  root="$(coyote_nix_xilinx_share_root)"
  for p in \
    "$root/$v/Vivado" \
    "$root/Vivado/$v"
  do
    if [ -d "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

coyote_nix_resolve_hls_root_by_version() {
  local root v p

  v="$1"
  root="$(coyote_nix_xilinx_share_root)"
  for p in \
    "$root/$v/Vitis_HLS" \
    "$root/Vitis_HLS/$v"
  do
    if [ -d "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

coyote_nix_pick_xilinx_version() {
  if [ -n "${COYOTE_NIX_XILINX_VERSION:-}" ] && coyote_nix_resolve_vivado_root_by_version "${COYOTE_NIX_XILINX_VERSION}" >/dev/null 2>&1; then
    printf '%s\n' "$COYOTE_NIX_XILINX_VERSION"
    return 0
  fi

  case "${FDEV_NAME:-}" in
    v80|*v80*|versal|*versal*)
      if coyote_nix_resolve_vivado_root_by_version "2025.1" >/dev/null 2>&1; then
        printf '%s\n' "2025.1"
        return 0
      fi
      ;;
    u280|*u280*|ultrascale*|*ultrascale*)
      if coyote_nix_resolve_vivado_root_by_version "2023.2" >/dev/null 2>&1; then
        printf '%s\n' "2023.2"
        return 0
      fi
      ;;
  esac

  local v
  for v in 2023.2 2025.1; do
    if coyote_nix_resolve_vivado_root_by_version "$v" >/dev/null 2>&1; then
      printf '%s\n' "$v"
      return 0
    fi
  done

  return 1
}

coyote_nix_pick_xilinx_version_for() {
  local probe_fn preferred v

  probe_fn="$1"

  if [ -n "${COYOTE_NIX_XILINX_VERSION:-}" ] && "$probe_fn" "${COYOTE_NIX_XILINX_VERSION}" >/dev/null 2>&1; then
    printf '%s\n' "$COYOTE_NIX_XILINX_VERSION"
    return 0
  fi

  preferred="$(coyote_nix_pick_xilinx_version 2>/dev/null || true)"
  if [ -n "$preferred" ] && "$probe_fn" "$preferred" >/dev/null 2>&1; then
    printf '%s\n' "$preferred"
    return 0
  fi

  mapfile -t coyote_nix_versions < <(coyote_nix_xilinx_versions)
  for v in "${coyote_nix_versions[@]}"; do
    [ -n "$v" ] || continue
    if "$probe_fn" "$v" >/dev/null 2>&1; then
      printf '%s\n' "$v"
      return 0
    fi
  done

  return 1
}

coyote_nix_strip_xilinx_from_path() {
  local root

  root="$(coyote_nix_xilinx_share_root)"
  PATH="$(printf '%s' "$PATH" | tr ':' '\n' | awk -v root="$root" '$0 !~ ("^" root "/")' | paste -sd: -)"
}

coyote_nix_find_vivado_bin() {
  local root v p

  v="$1"
  root="$(coyote_nix_xilinx_share_root)"
  for p in \
    "$root/$v/Vivado/bin/vivado" \
    "$root/Vivado/$v/bin/vivado"
  do
    if [ -x "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

coyote_nix_find_vivado_settings() {
  local root v p

  v="$1"
  root="$(coyote_nix_xilinx_share_root)"
  for p in \
    "$root/$v/Vivado/settings64.sh" \
    "$root/Vivado/$v/settings64.sh"
  do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

coyote_nix_find_vitis_hls_bin() {
  local root v p

  v="$1"
  root="$(coyote_nix_xilinx_share_root)"
  for p in \
    "$root/$v/Vitis_HLS/bin/vitis_hls" \
    "$root/Vitis_HLS/$v/bin/vitis_hls"
  do
    if [ -x "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

coyote_nix_find_vitis_run_bin() {
  local root v p

  v="$1"
  root="$(coyote_nix_xilinx_share_root)"
  for p in \
    "$root/$v/Vitis/bin/vitis-run" \
    "$root/Vitis/$v/bin/vitis-run"
  do
    if [ -x "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

coyote_nix_license_file() {
  if [ -n "${COYOTE_NIX_XILINX_LICENSE_FILE:-}" ]; then
    printf '%s\n' "$COYOTE_NIX_XILINX_LICENSE_FILE"
    return 0
  fi

  return 1
}

coyote_nix_export_license_env() {
  local license_file

  license_file="$(coyote_nix_license_file 2>/dev/null || true)"
  if [ -n "$license_file" ]; then
    export XILINXD_LICENSE_FILE="$license_file"
    export XILINX_LICENSE_FILE="$license_file"
    export LM_LICENSE_FILE="$license_file"
  fi
}

coyote_nix_license_exports() {
  local license_file

  license_file="$(coyote_nix_license_file 2>/dev/null || true)"
  if [ -n "$license_file" ]; then
    local q_license
    q_license="$(coyote_nix_shell_quote "$license_file")"
    printf '%s' "export XILINXD_LICENSE_FILE=$q_license; export XILINX_LICENSE_FILE=$q_license; export LM_LICENSE_FILE=$q_license;"
  fi
}

coyote_nix_export_ncurses_compat() {
  local ncurses6_lib ncurses6_libdir

  ncurses6_lib="${COYOTE_NIX_NCURSES6_LIB:-$coyote_nix_default_ncurses6_lib}"
  if [ -z "$ncurses6_lib" ]; then
    return 0
  fi

  export COYOTE_NIX_NCURSES6_LIB="$ncurses6_lib"
  if [ -e "$ncurses6_lib" ]; then
    ncurses6_libdir="$(dirname "$ncurses6_lib")"
    case ":${LD_LIBRARY_PATH:-}:" in
      *":$ncurses6_libdir:"*) ;;
      *) export LD_LIBRARY_PATH="$ncurses6_libdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
    esac
  fi
}

coyote_nix_export_gmake_compat() {
  local compat_dir make_bin

  compat_dir="$HOME/bin"
  mkdir -p "$compat_dir"

  make_bin="$(command -v make 2>/dev/null || true)"
  if [ -n "$make_bin" ]; then
    ln -sf "$make_bin" "$compat_dir/gmake"
  fi

  case ":${PATH:-}:" in
    *":$compat_dir:"*) ;;
    *) export PATH="$compat_dir${PATH:+:$PATH}" ;;
  esac
}

coyote_nix_export_wrapper_env() {
  coyote_nix_export_ncurses_compat
  coyote_nix_export_license_env
  coyote_nix_export_gmake_compat
}

coyote_nix_wrapper_shell_exports() {
  local out ncurses6_lib ncurses6_libdir q_ncurses6_lib q_ncurses6_libdir q_license q_compat_dir license_file

  out=""
  ncurses6_lib="${COYOTE_NIX_NCURSES6_LIB:-$coyote_nix_default_ncurses6_lib}"
  if [ -n "$ncurses6_lib" ]; then
    q_ncurses6_lib="$(coyote_nix_shell_quote "$ncurses6_lib")"
    out="$out export COYOTE_NIX_NCURSES6_LIB=$q_ncurses6_lib;"

    if [ -e "$ncurses6_lib" ]; then
      ncurses6_libdir="$(dirname "$ncurses6_lib")"
      q_ncurses6_libdir="$(coyote_nix_shell_quote "$ncurses6_libdir")"
      out="$out case \":\${LD_LIBRARY_PATH:-}:\" in *:$q_ncurses6_libdir:*) ;; *) export LD_LIBRARY_PATH=$q_ncurses6_libdir\"\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\" ;; esac;"
    fi
  fi

  license_file="$(coyote_nix_license_file 2>/dev/null || true)"
  if [ -n "$license_file" ]; then
    q_license="$(coyote_nix_shell_quote "$license_file")"
    out="$out export XILINXD_LICENSE_FILE=$q_license; export XILINX_LICENSE_FILE=$q_license; export LM_LICENSE_FILE=$q_license;"
  fi

  q_compat_dir="$(coyote_nix_shell_quote "$HOME/bin")"
  out="$out mkdir -p $q_compat_dir;"
  out="$out if command -v make >/dev/null 2>&1; then ln -sf \"\$(command -v make)\" $q_compat_dir/gmake; fi;"
  out="$out case \":\${PATH:-}:\" in *:$q_compat_dir:*) ;; *) export PATH=$q_compat_dir\"\${PATH:+:\$PATH}\" ;; esac;"

  printf '%s\n' "$out"
}

coyote_nix_resolve_xilinx_shell() {
  if [ -n "${COYOTE_NIX_XILINX_SHELL:-}" ] && [ -x "${COYOTE_NIX_XILINX_SHELL}" ]; then
    printf '%s\n' "$COYOTE_NIX_XILINX_SHELL"
    return 0
  fi

  if command -v xilinx-shell >/dev/null 2>&1; then
    command -v xilinx-shell
    return 0
  fi

  if [ -x /run/current-system/sw/bin/xilinx-shell ]; then
    printf '%s\n' /run/current-system/sw/bin/xilinx-shell
    return 0
  fi

  return 1
}

coyote_nix_exec_in_xilinx_shell() {
  local xilinx_shell

  xilinx_shell="$(coyote_nix_resolve_xilinx_shell 2>/dev/null || true)"
  if [ -z "$xilinx_shell" ]; then
    echo "xilinx-shell not found; set COYOTE_NIX_XILINX_SHELL or provide xilinx-shell in PATH" >&2
    return 127
  fi
  exec "$xilinx_shell" -c "$1" -- "${@:2}"
}

coyote_nix_exec_xilinx_shell_command() {
  local version command prelude settings q_settings

  version="$1"
  command="$2"
  shift 2

  coyote_nix_export_wrapper_env
  prelude="$(coyote_nix_wrapper_shell_exports)"
  settings="$(coyote_nix_find_vivado_settings "$version" 2>/dev/null || true)"

  if [ -n "$settings" ]; then
    q_settings="$(coyote_nix_shell_quote "$settings")"
    coyote_nix_exec_in_xilinx_shell "$prelude source $q_settings >/dev/null 2>&1 || true; $prelude $command" "$@"
  else
    coyote_nix_exec_in_xilinx_shell "$prelude $command" "$@"
  fi
}

coyote_nix_exec_xilinx_tool() {
  local version tool_bin q_tool_bin

  version="$1"
  tool_bin="$2"
  shift 2

  q_tool_bin="$(coyote_nix_shell_quote "$tool_bin")"
  coyote_nix_exec_xilinx_shell_command "$version" "exec $q_tool_bin \"\$@\"" "$@"
}
