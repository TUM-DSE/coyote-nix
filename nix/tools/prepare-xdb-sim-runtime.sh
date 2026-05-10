#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <source-sim-dir> <runtime-root> [xilinx-version] [project-file]" >&2
  exit 2
}

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  usage
fi

source_sim_dir="$1"
runtime_root="$2"
xilinx_version="${3:-}"
project_file="${4:-${XDB_SIM_PROJECT_FILE:-}}"
compile_script=""
elaborate_script=""
simulate_script=""
runtime_project=""

if [ ! -d "$source_sim_dir" ]; then
  echo "ERROR: source simulation directory does not exist: $source_sim_dir" >&2
  exit 1
fi

install_sim_tree() {
  mkdir -p "$runtime_root"
  cp -r "$source_sim_dir/." "$runtime_root/"
}

rewrite_runtime_paths() {
  while IFS= read -r file; do
    case "$file" in
      *.sh|*.prj|*.ini|*.tcl)
        perl -0pi \
          -e "s#\Q$source_sim_dir\E#$runtime_root#g;" \
          -e 's#(?:\.\./)+nix/store/#/nix/store/#g;' \
          "$file"
        ;;
    esac
  done < <(find "$runtime_root" -type f | sort)
}

inject_xilinx_version() {
  local file tmp

  [ -n "$xilinx_version" ] || return 0

  while IFS= read -r file; do
    if grep -q '^export COYOTE_NIX_XILINX_VERSION=' "$file"; then
      continue
    fi

    tmp="$file.tmp"
    awk -v version="$xilinx_version" '
      NR == 1 && /^#!/ {
        print
        print "export COYOTE_NIX_XILINX_VERSION=\"" version "\""
        next
      }
      { print }
    ' "$file" > "$tmp"
    chmod --reference="$file" "$tmp"
    mv "$tmp" "$file"
  done < <(find "$runtime_root" -type f -name '*.sh' | sort)
}

discover_runtime_scripts() {
  compile_script="$(find "$runtime_root" -type f -name compile.sh | sort | head -n1)"
  elaborate_script="$(find "$runtime_root" -type f -name elaborate.sh | sort | head -n1)"
  simulate_script="$(find "$runtime_root" -type f -name simulate.sh | sort | head -n1)"

  if [ -z "$compile_script" ] || [ -z "$elaborate_script" ] || [ -z "$simulate_script" ]; then
    echo "ERROR: exported simulation runtime bundle is incomplete under $runtime_root" >&2
    exit 1
  fi
}

discover_runtime_project() {
  if [ -n "$project_file" ]; then
    if [ -f "$runtime_root/$project_file" ]; then
      runtime_project="$runtime_root/$project_file"
      return 0
    fi
    if [ -f "$project_file" ]; then
      runtime_project="$project_file"
      return 0
    fi
    echo "ERROR: simulation project file not found: $project_file" >&2
    exit 1
  fi

  runtime_project="$(find "$runtime_root" -maxdepth 2 -type f -name '*.xpr' | sort | head -n1)"
  if [ -z "$runtime_project" ]; then
    echo "ERROR: no Vivado .xpr project found under $runtime_root" >&2
    echo "Hint: pass the project filename as the fourth argument." >&2
    exit 1
  fi
}

write_runtime_metadata() {
  local compile_rel elaborate_rel simulate_rel work_dir_rel project_escaped

  compile_rel="${compile_script#"$runtime_root"/}"
  elaborate_rel="${elaborate_script#"$runtime_root"/}"
  simulate_rel="${simulate_script#"$runtime_root"/}"
  work_dir_rel="$(dirname "$compile_rel")"
  project_escaped="$(printf '%s' "$runtime_project" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  cat > "$runtime_root/xdb-runtime.json" <<EOF
{
  "format": 1,
  "project": "$project_escaped",
  "work_dir": "$work_dir_rel",
  "compile_script": "$compile_rel",
  "elaborate_script": "$elaborate_rel",
  "simulate_script": "$simulate_rel"
}
EOF
}

install_sim_tree
rewrite_runtime_paths
inject_xilinx_version
discover_runtime_scripts
discover_runtime_project
write_runtime_metadata
