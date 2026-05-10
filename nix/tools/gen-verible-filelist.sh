#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-verible.filelist}"

# Prefer tracked files (stable, ignores build outputs). Fallback to find.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t sv_files < <(
    git ls-files \
      '*.sv' '*.svh' '*.v' '*.vh' \
      | sort -u
  )
else
  mapfile -t sv_files < <(
    find . -type f \( -name '*.sv' -o -name '*.svh' -o -name '*.v' -o -name '*.vh' \) \
      | sed 's#^\./##' \
      | sort -u
  )
fi

# Build include dirs from file parent dirs.
mapfile -t incdirs < <(
  printf '%s\n' "${sv_files[@]}" \
    | xargs -n1 dirname \
    | sort -u
)

{
  echo "# Auto-generated. Do not edit manually."
  echo "# Regenerate with: scripts/gen-verible-filelist.sh"
  echo

  for d in "${incdirs[@]}"; do
    echo "+incdir+$d"
  done

  echo
  printf '%s\n' "${sv_files[@]}"
} > "$OUT"
