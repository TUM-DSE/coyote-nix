#!/usr/bin/env bash
set -euo pipefail

common=${1:?usage: deploy-hw-vermagic.sh COYOTE_COMMON DEPLOY_HW}
deploy_hw=${2:?usage: deploy-hw-vermagic.sh COYOTE_COMMON DEPLOY_HW}
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fake_bin="$workdir/bin"
project="$workdir/project"
driver_package="$workdir/driver-package"
driver_ko="$driver_package/coyote_driver.ko"
image="$workdir/image.bit"
side_effect_log="$workdir/side-effects.log"
inspection_log="$workdir/inspection.log"
mkdir -p "$fake_bin" "$project" "$driver_package"
touch "$project/flake.nix" "$driver_ko" "$image" "$side_effect_log" "$inspection_log"

cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
test "$1" = rev-parse
test "$2" = --show-toplevel
printf '%s\n' "$COYOTE_TEST_PROJECT_ROOT"
EOF

cat > "$fake_bin/nix" <<'EOF'
#!/usr/bin/env bash
printf 'nix' >> "$COYOTE_TEST_INSPECTION_LOG"
printf '\t%s' "$@" >> "$COYOTE_TEST_INSPECTION_LOG"
printf '\n' >> "$COYOTE_TEST_INSPECTION_LOG"
test "$1" = build
test "$2" = --no-link
test "$3" = --print-out-paths
test "$4" = "$COYOTE_TEST_PROJECT_ROOT#$COYOTE_DRIVER_PACKAGE"
printf '%s\n' "$COYOTE_TEST_DRIVER_PACKAGE"
EOF

cat > "$fake_bin/modinfo" <<'EOF'
#!/usr/bin/env bash
printf 'modinfo' >> "$COYOTE_TEST_INSPECTION_LOG"
printf '\t%s' "$@" >> "$COYOTE_TEST_INSPECTION_LOG"
printf '\n' >> "$COYOTE_TEST_INSPECTION_LOG"
test "$1" = -F
test "$2" = vermagic
test "$3" = "$COYOTE_TEST_DRIVER_KO"
printf '%s\n' "$COYOTE_TEST_VERMAGIC"
EOF

cat > "$fake_bin/uname" <<'EOF'
#!/usr/bin/env bash
test "$1" = -r
printf '%s\n' "$COYOTE_TEST_KERNEL_RELEASE"
EOF

for command_name in unload-driver hot-reset program-cli set-hugepages insert-driver; do
  cat > "$fake_bin/$command_name" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${0##*/}" >> "$COYOTE_TEST_SIDE_EFFECT_LOG"
if [ "$#" -gt 0 ]; then
  printf '\t%s' "$@" >> "$COYOTE_TEST_SIDE_EFFECT_LOG"
fi
printf '\n' >> "$COYOTE_TEST_SIDE_EFFECT_LOG"
EOF
done

bash_path=$(command -v bash)
for helper in "$fake_bin"/*; do
  sed -i "1s|.*|#!$bash_path|" "$helper"
done
chmod +x "$fake_bin"/*

run_deploy() {
  local vermagic="$1"

  PATH="$fake_bin:$PATH" \
  COYOTE_TEST_PROJECT_ROOT="$project" \
  COYOTE_TEST_DRIVER_PACKAGE="$driver_package" \
  COYOTE_TEST_DRIVER_KO="$driver_ko" \
  COYOTE_TEST_VERMAGIC="$vermagic" \
  COYOTE_TEST_KERNEL_RELEASE="7.1.9-test" \
  COYOTE_TEST_SIDE_EFFECT_LOG="$side_effect_log" \
  COYOTE_TEST_INSPECTION_LOG="$inspection_log" \
  TARGET_PLATFORM=ultrascale_plus \
  FDEV_NAME=u280 \
  FPGA_BDF=0000:c1:00.0 \
  COYOTE_DRIVER_PACKAGE=selected-driver \
    bash -c '
      common=$1
      deploy_hw=$2
      shift 2
      source "$common"
      source "$deploy_hw"
    ' _ "$common" "$deploy_hw" --timeout 0 --program-timeout 0 "$image"
}

set +e
mismatch_output=$(run_deploy "6.9.0-test SMP preempt mod_unload" 2>&1)
mismatch_status=$?
set -e

test "$mismatch_status" -ne 0
printf '%s\n' "$mismatch_output" | grep -F \
  'ERROR: driver module vermagic does not match the running kernel.' >/dev/null
printf '%s\n' "$mismatch_output" | grep -F \
  'Module kernel release: 6.9.0-test' >/dev/null
printf '%s\n' "$mismatch_output" | grep -F \
  'Running kernel release: 7.1.9-test' >/dev/null
if [ -s "$side_effect_log" ]; then
  echo "ERROR: deploy-hw performed a side effect after a vermagic mismatch" >&2
  cat "$side_effect_log" >&2
  exit 1
fi
if printf '%s\n' "$mismatch_output" | grep -F '[1/7]' >/dev/null; then
  echo "ERROR: deploy-hw began its side-effect sequence after a vermagic mismatch" >&2
  exit 1
fi

grep -F $'modinfo\t-F\tvermagic\t'"$driver_ko" "$inspection_log" >/dev/null

: > "$side_effect_log"
match_output=$(run_deploy "7.1.9-test SMP preempt mod_unload" 2>&1)
printf '%s\n' "$match_output" | grep -F '[1/7] unloading driver' >/dev/null
printf '%s\n' "$match_output" | grep -F '[7/7] complete.' >/dev/null

mapfile -t side_effects < "$side_effect_log"
test "${#side_effects[@]}" -eq 6
test "${side_effects[0]}" = 'unload-driver'
test "${side_effects[1]}" = 'hot-reset'
test "${side_effects[2]}" = $'program-cli\t'"$image"
test "${side_effects[3]}" = 'hot-reset'
test "${side_effects[4]}" = 'set-hugepages'
test "${side_effects[5]}" = $'insert-driver\t'"$driver_ko"$'\t'"$image"
