usage() {
  echo "Usage: program-cli [image.bit|image.pdi]" >&2
  echo "Program an FPGA image with Vivado. Defaults may come from FPGA_BITSTREAM or the active dev shell." >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [ $# -gt 1 ]; then
  usage
  exit 1
fi

activate_xilinx program-cli "$@"

project_root="$(resolve_project_root)"
platform="${FDEV_NAME:-u280}"
build_root="${COYOTE_NIX_BUILD_ROOT:-$project_root/.build}"

default_package=""
default_image=""
if [ $# -eq 0 ] && [ -z "${FPGA_BITSTREAM:-}" ]; then
  default_package="$(resolve_fpga_package_name "$platform" 2>/dev/null || true)"
  if [ -n "$default_package" ]; then
    default_image="$(resolve_default_fpga_image_from_package "$platform" 2>/dev/null || true)"
  fi
fi

image="${1:-${FPGA_BITSTREAM:-$default_image}}"
part_hint="${FPGA_PART_HINT:-}"

if [ -z "$part_hint" ]; then
  echo "ERROR: FPGA_PART_HINT is required (e.g. export FPGA_PART_HINT=<device-part-substring>)." >&2
  exit 1
fi

case "$image" in
  *.bit|*.pdi) ;;
  *)
    echo "Image must be a .bit or .pdi file." >&2
    exit 1
    ;;
esac

if [ ! -f "$image" ] && [ -f "$project_root/$image" ]; then
  image="$project_root/$image"
fi
if [ ! -f "$image" ]; then
  echo "Image not found: $image" >&2
  if [ -n "$default_image" ]; then
    echo "Default packaged image checked: $default_image" >&2
  elif [ -n "$default_package" ]; then
    echo "Default package checked: $default_package" >&2
  fi
  echo "Hint: pass an explicit image path, or set FPGA_BITSTREAM=/path/to/image.{bit,pdi}." >&2
  exit 1
fi

require_cmd vivado
require_cmd hw_server

hw_server_pid=""
vivado_pid=""
tcl_file=""
program_lock_dir="${COYOTE_NIX_PROGRAM_LOCK_DIR:-/tmp/coyote-program-cli.lock}"
program_lock_acquired=0

cleanup_program_cli() {
  if [ -n "$vivado_pid" ] && kill -0 "$vivado_pid" 2>/dev/null; then
    kill "$vivado_pid" 2>/dev/null || true
    wait "$vivado_pid" 2>/dev/null || true
  fi

  if [ -n "$hw_server_pid" ] && kill -0 "$hw_server_pid" 2>/dev/null; then
    kill "$hw_server_pid" 2>/dev/null || true
    wait "$hw_server_pid" 2>/dev/null || true
  fi

  if [ -n "$tcl_file" ] && [ -f "$tcl_file" ]; then
    rm -f "$tcl_file"
  fi

  if [ "$program_lock_acquired" = "1" ] && [ -d "$program_lock_dir" ]; then
    rm -rf "$program_lock_dir" 2>/dev/null || true
  fi
}

trap cleanup_program_cli EXIT
trap 'exit 130' INT TERM

acquire_program_lock() {
  if mkdir "$program_lock_dir" 2>/dev/null; then
    program_lock_acquired=1
    {
      printf 'user=%s\n' "$(id -un 2>/dev/null || id -u)"
      printf 'uid=%s\n' "$(id -u)"
      printf 'pid=%s\n' "$$"
      printf 'started=%s\n' "$(date -Is 2>/dev/null || date)"
      printf 'cwd=%s\n' "$PWD"
    } >"$program_lock_dir/info" 2>/dev/null || true
    return 0
  fi

  echo "ERROR: another program-cli/deploy-hw invocation appears to be running." >&2
  echo "Refusing to interfere with its hw_server." >&2
  echo >&2
  echo "Lock: $program_lock_dir" >&2
  if [ -r "$program_lock_dir/info" ]; then
    echo "Lock owner:" >&2
    sed 's/^/  /' "$program_lock_dir/info" >&2 || true
  fi
  echo >&2
  echo "If this is a stale lock, remove it manually after checking that no programming job is active." >&2
  exit 1
}

find_foreign_hw_servers() {
  local current_uid pid pid_uid info

  current_uid="$(id -u)"
  for pid in $(pgrep -x hw_server || true); do
    pid_uid="$(ps -o uid= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
    [ -n "$pid_uid" ] || continue

    if [ "$pid_uid" != "$current_uid" ]; then
      info="$(ps -o user= -o pid= -o args= -p "$pid" 2>/dev/null || true)"
      if [ -n "$info" ]; then
        printf '%s\n' "$info"
      else
        printf 'uid=%s pid=%s hw_server\n' "$pid_uid" "$pid"
      fi
    fi
  done
}

stop_own_hw_servers() {
  local current_uid pid pid_uid remaining_pids attempts
  local own_pids=()

  current_uid="$(id -u)"
  for pid in $(pgrep -x hw_server || true); do
    pid_uid="$(ps -o uid= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
    [ -n "$pid_uid" ] || continue

    if [ "$pid_uid" = "$current_uid" ]; then
      own_pids+=("$pid")
    fi
  done

  if [ "${#own_pids[@]}" -eq 0 ]; then
    return 0
  fi

  echo "Stopping existing hw_server process(es): ${own_pids[*]}"
  kill "${own_pids[@]}" 2>/dev/null || true

  attempts=0
  while [ "$attempts" -lt 10 ]; do
    remaining_pids=()
    for pid in "${own_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        remaining_pids+=("$pid")
      fi
    done

    if [ "${#remaining_pids[@]}" -eq 0 ]; then
      return 0
    fi

    sleep 0.2
    attempts=$((attempts + 1))
  done

  echo "ERROR: hw_server process(es) did not exit after SIGTERM: ${remaining_pids[*]}" >&2
  echo "Refusing to force-kill them; another programming/debug session may be active." >&2
  echo "Stop them manually if they are stale, then retry program-cli." >&2
  exit 1
}

acquire_program_lock

foreign_hw_servers="$(find_foreign_hw_servers)"
if [ -n "$foreign_hw_servers" ]; then
  echo "ERROR: refusing to use an existing hw_server owned by another user." >&2
  echo "Ask the owner/admin to stop it, then retry program-cli." >&2
  echo >&2
  echo "Existing foreign hw_server process(es):" >&2
  printf '%s\n' "$foreign_hw_servers" >&2
  exit 1
fi

# Vivado and hw_server major versions must match. Restart any existing
# current-user hw_server so this invocation uses the shell-selected version.
stop_own_hw_servers

hw_server -s tcp::3121 >/tmp/hw_server.log 2>&1 &
hw_server_pid="$!"
sleep 2

if ! kill -0 "$hw_server_pid" 2>/dev/null; then
  echo "ERROR: hw_server exited before programming started." >&2
  echo "hw_server log:" >&2
  sed 's/^/  /' /tmp/hw_server.log >&2 || true
  exit 1
fi

foreign_hw_servers="$(find_foreign_hw_servers)"
if [ -n "$foreign_hw_servers" ]; then
  echo "ERROR: a foreign hw_server appeared after starting our hw_server; refusing to continue." >&2
  echo "Existing foreign hw_server process(es):" >&2
  printf '%s\n' "$foreign_hw_servers" >&2
  exit 1
fi

tcl_file="$(mktemp /tmp/coyote_program.XXXXXX.tcl)"
cat > "$tcl_file" <<'TCL'
if {$argc < 2} {
  puts "Usage: vivado -mode batch -source <tcl> -tclargs <image> <part_hint>"
  exit 1
}
set image  [lindex $argv 0]
set needle [string tolower [lindex $argv 1]]

open_hw_manager
connect_hw_server -url localhost:3121

set tgts [get_hw_targets]
if {[llength $tgts] == 0} {
  puts "No hw targets found"
  exit 3
}

set matches {}
set match_targets {}

foreach t $tgts {
  puts "Scanning target: $t"
  set rc [catch {open_hw_target $t} open_msg]
  if {$rc != 0} {
    puts "Skipping target $t: $open_msg"
    continue
  }

  foreach d [get_hw_devices] {
    set part [string tolower [get_property PART $d]]
    puts "Found device: $d  PART=$part  TARGET=$t"
    if {[string first $needle $part] >= 0} {
      lappend matches $d
      lappend match_targets $t
    }
  }

  catch {close_hw_target $t}
}

if {[llength $matches] != 1} {
  puts "Expected exactly one device matching '$needle', got [llength $matches]"
  for {set i 0} {$i < [llength $matches]} {incr i} {
    puts "  match [expr {$i + 1}]: [lindex $matches $i] on [lindex $match_targets $i]"
  }
  exit 2
}

set dev [lindex $matches 0]
set tgt [lindex $match_targets 0]

if {[catch {open_hw_target $tgt} open_msg] != 0} {
  puts "Failed to reopen matching target $tgt: $open_msg"
  exit 4
}

current_hw_device $dev
refresh_hw_device $dev
set_property PROGRAM.FILE $image $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "OK: programmed $dev with $image"

catch {close_hw_target $tgt}
disconnect_hw_server
close_hw_manager
exit 0
TCL

log_dir="$build_root/logs/program-cli"
mkdir -p "$log_dir"
stamp="$(date +%Y%m%d-%H%M%S)"
vivado_log="$log_dir/program-${stamp}.log"
vivado_jou="$log_dir/program-${stamp}.jou"

echo "Vivado log: $vivado_log"
echo "Vivado journal: $vivado_jou"
vivado -mode batch -log "$vivado_log" -journal "$vivado_jou" -source "$tcl_file" -tclargs "$image" "$part_hint" &
vivado_pid="$!"

set +e
wait "$vivado_pid"
vivado_rc=$?
set -e
vivado_pid=""

if [ "$vivado_rc" -ne 0 ]; then
  exit "$vivado_rc"
fi

echo
