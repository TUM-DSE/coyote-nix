export COYOTE_ROOT="@COYOTE_ROOT@"

project_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

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
