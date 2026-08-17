#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper_lib="$repo_root/nix/tools/xilinx-wrapper-lib.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

coreutils_bin="$(dirname "$(command -v mkdir)")"
bash_bin="$(dirname "$(command -v bash)")"

# If the environment already provides gmake, leave PATH and HOME untouched.
mkdir -p "$test_root/existing-bin" "$test_root/home-existing"
printf '#!/bin/sh\nexit 0\n' > "$test_root/existing-bin/make"
printf '#!/bin/sh\nexit 0\n' > "$test_root/existing-bin/gmake"
chmod +x "$test_root/existing-bin/make" "$test_root/existing-bin/gmake"
HOME="$test_root/home-existing" \
PATH="$test_root/existing-bin:$coreutils_bin:$bash_bin" \
COYOTE_NIX_TEST_WRAPPER_LIB="$wrapper_lib" \
bash -c '
  # shellcheck source=/dev/null
  source "$COYOTE_NIX_TEST_WRAPPER_LIB"
  old_path=$PATH
  coyote_nix_export_gmake_compat
  test "$PATH" = "$old_path"
  test ! -e "$HOME/bin"
'

# Older environments get an ephemeral shim in the configured runtime path.
mkdir -p "$test_root/fallback-bin" "$test_root/home-fallback"
printf '#!/bin/sh\nprintf "fake make\\n"\n' > "$test_root/fallback-bin/make"
chmod +x "$test_root/fallback-bin/make"
compat_dir="$test_root/runtime dir/bin"
HOME="$test_root/home-fallback" \
PATH="$test_root/fallback-bin:$coreutils_bin:$bash_bin" \
COYOTE_NIX_GMAKE_COMPAT_DIR="$compat_dir" \
COYOTE_NIX_TEST_WRAPPER_LIB="$wrapper_lib" \
bash -c '
  # shellcheck source=/dev/null
  source "$COYOTE_NIX_TEST_WRAPPER_LIB"
  coyote_nix_export_gmake_compat
  test "$(command -v gmake)" = "$COYOTE_NIX_GMAKE_COMPAT_DIR/gmake"
  test "$(gmake)" = "fake make"
  test ! -e "$HOME/bin"
'

# The generated prelude used inside xilinx-shell follows the same rules.
rm -rf "$compat_dir"
HOME="$test_root/home-wrapper" \
PATH="$test_root/fallback-bin:$coreutils_bin:$bash_bin" \
COYOTE_NIX_GMAKE_COMPAT_DIR="$compat_dir" \
COYOTE_NIX_TEST_WRAPPER_LIB="$wrapper_lib" \
bash -c '
  # shellcheck source=/dev/null
  source "$COYOTE_NIX_TEST_WRAPPER_LIB"
  prelude=$(coyote_nix_wrapper_shell_exports)
  bash -c "$prelude
    test \"\$(command -v gmake)\" = \"$COYOTE_NIX_GMAKE_COMPAT_DIR/gmake\"
    test \"\$XILINX_LOCAL_USER_DATA\" = no
    test ! -e \"$HOME/bin\""

  XILINX_LOCAL_USER_DATA=yes bash -c "$prelude
    test \"\$XILINX_LOCAL_USER_DATA\" = yes"
'
