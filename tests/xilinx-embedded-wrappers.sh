#!/usr/bin/env bash
set -euo pipefail

source_root="${1:?usage: xilinx-embedded-wrappers.sh SOURCE_ROOT}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/wrappers" "$work/share"
sed -e "s|@XILINX_SHARE_ROOT@|$work/share|g" \
    -e 's|@NCURSES6_LIB@||g' \
    "$source_root/nix/tools/xilinx-wrapper-lib.sh" > "$work/library.sh"
for tool in xsdb bootgen armr5-none-eabi-gcc armr5-none-eabi-readelf; do
  sed -e "s|@XILINX_WRAPPER_LIB@|$work/library.sh|g" \
      -e "1s|.*|#!$(command -v bash)|" \
    "$source_root/nix/tools/xilinx-embedded-wrapper.sh" > "$work/wrappers/$tool"
  chmod +x "$work/wrappers/$tool"
done

# A shell stand-in executes only locally generated fixtures, never vendor code.
cat > "$work/xilinx-shell" <<EOF
#!$(command -v bash)
printf 'entered\n' >> "$work/shell-calls"
exec "$(command -v bash)" "\$@"
EOF
chmod +x "$work/xilinx-shell"
export COYOTE_NIX_XILINX_SHELL="$work/xilinx-shell"
unset COYOTE_NIX_NCURSES6_LIB

# Exercise both supported installation layouts, with distinguishable versions.
for version in 2023.2 2024.2; do
  if [ "$version" = 2023.2 ]; then
    root="$work/share/$version/Vitis"
  else
    root="$work/share/Vitis/$version"
  fi
  mkdir -p "$root/bin" "$root/gnu/armr5/lin/gcc-arm-none-eabi/bin"
  printf 'export XILINX_VITIS=%q\n' "$root" > "$root/.settings64-Vitis.sh"
  for tool in xsdb bootgen armr5-none-eabi-gcc armr5-none-eabi-readelf; do
    case "$tool" in
      armr5-*) bin="$root/gnu/armr5/lin/gcc-arm-none-eabi/bin" ;;
      *) bin="$root/bin" ;;
    esac
    cat > "$bin/$tool" <<EOF
#!$(command -v bash)
printf '%s\\0' '$version' '$tool' "\$XILINX_VITIS" "\$@"
exit "\${FIXTURE_EXIT_CODE:-0}"
EOF
    chmod +x "$bin/$tool"
  done
  export COYOTE_NIX_XILINX_VERSION="$version"
  export XILINX_VITIS=stale-version
  args=(-eval 'puts {a b}' '' 'literal;$[command]' $'line\nbreak' '--' '*.tcl')
  for tool in xsdb bootgen armr5-none-eabi-gcc armr5-none-eabi-readelf; do
    printf '%s\0' "$version" "$tool" "$root" "${args[@]}" > "$work/expected"
    "$work/wrappers/$tool" "${args[@]}" > "$work/actual"
    cmp "$work/expected" "$work/actual"
  done
done

if FIXTURE_EXIT_CODE=37 "$work/wrappers/xsdb" > /dev/null; then
  echo 'XSDB wrapper lost tool failure status' >&2
  exit 1
else
  test "$?" -eq 37
fi

expect_failure() {
  local diagnostic="$1"
  rm -f "$work/shell-calls"
  if "$work/wrappers/xsdb" -help > "$work/stdout" 2> "$work/stderr"; then
    echo 'Unexpected XSDB success' >&2
    exit 1
  fi
  grep -F -- "$diagnostic" "$work/stderr"
  test ! -e "$work/shell-calls"
  test ! -s "$work/stdout"
}

# An installed version without XSDB must not fall back to another version.
rm "$work/share/Vitis/2024.2/bin/xsdb"
expect_failure 'xsdb not found in Vitis 2024.2'
# A non-executable file is absent for executable resolution too.
printf 'not executable\n' > "$work/share/Vitis/2024.2/bin/xsdb"
expect_failure 'xsdb not found in Vitis 2024.2'
export COYOTE_NIX_XILINX_VERSION=2099.1
expect_failure 'No complete Vitis installation found'
unset COYOTE_NIX_XILINX_VERSION
expect_failure 'COYOTE_NIX_XILINX_VERSION=<unset>'
echo 'Embedded wrapper mock tests passed'
