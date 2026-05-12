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
require_cmd setsid

umask 000

hw_server_pid=""
hw_server_pgid=""
vivado_pid=""
tcl_file=""
hw_server_port="$(coyote_nix_hw_server_port)"
hw_server_url="localhost:$hw_server_port"
program_lock_platform="${platform//[^a-zA-Z0-9_.-]/_}"
program_lock_dir="${COYOTE_NIX_PROGRAM_LOCK_DIR:-/tmp/coyote-program-cli-$program_lock_platform-$hw_server_port.lock}"
program_lock_acquired=0

cleanup_program_cli() {
  if [ -n "$vivado_pid" ] && kill -0 "$vivado_pid" 2>/dev/null; then
    kill "$vivado_pid" 2>/dev/null || true
    wait "$vivado_pid" 2>/dev/null || true
  fi

  if [ -n "$hw_server_pgid" ]; then
    kill -- "-$hw_server_pgid" 2>/dev/null || true
  elif [ -n "$hw_server_pid" ]; then
    kill "$hw_server_pid" 2>/dev/null || true
  fi
  if [ -n "$hw_server_pid" ]; then
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
      printf 'platform=%s\n' "$platform"
      printf 'hw_server_port=%s\n' "$hw_server_port"
    } >"$program_lock_dir/info" 2>/dev/null || true
    return 0
  fi

  echo "ERROR: another program-cli/deploy-hw invocation appears to be running for platform '$platform' on hw_server port $hw_server_port." >&2
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

hw_server_uses_port() {
  local pid="$1" arg saw_s url
  local args=()

  if ! mapfile -d "" -t args <"/proc/$pid/cmdline" 2>/dev/null; then
    return 0
  fi

  saw_s=0
  for arg in "${args[@]}"; do
    if [ "$saw_s" = "1" ]; then
      url="$arg"
      case "$url" in
        *":$hw_server_port"|"$hw_server_port") return 0 ;;
        *) return 1 ;;
      esac
    fi

    case "$arg" in
      -s)
        saw_s=1
        ;;
      -s*)
        url="${arg#-s}"
        [ -n "$url" ] || continue
        case "$url" in
          *":$hw_server_port"|"$hw_server_port") return 0 ;;
          *) return 1 ;;
        esac
        ;;
    esac
  done

  # hw_server defaults to tcp::3121 when no -s option is present.
  [ "$hw_server_port" = "3121" ]
}

find_foreign_hw_servers() {
  local current_uid pid pid_uid info

  current_uid="$(id -u)"
  for pid in $(pgrep -x hw_server || true); do
    hw_server_uses_port "$pid" || continue
    pid_uid="$(ps -o uid= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
    [ -n "$pid_uid" ] || continue

    if [ "$pid_uid" != "$current_uid" ]; then
      info="$(ps -o user= -o pid= -o args= -p "$pid" 2>/dev/null || true)"
      if [ -n "$info" ]; then
        printf '%s\n' "$info"
      else
        printf 'uid=%s pid=%s hw_server port=%s\n' "$pid_uid" "$pid" "$hw_server_port"
      fi
    fi
  done
}

stop_own_hw_servers() {
  local current_uid pid pid_uid remaining_pids attempts
  local own_pids=()

  current_uid="$(id -u)"
  for pid in $(pgrep -x hw_server || true); do
    hw_server_uses_port "$pid" || continue
    pid_uid="$(ps -o uid= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
    [ -n "$pid_uid" ] || continue

    if [ "$pid_uid" = "$current_uid" ]; then
      own_pids+=("$pid")
    fi
  done

  if [ "${#own_pids[@]}" -eq 0 ]; then
    return 0
  fi

  echo "Stopping existing hw_server process(es) on port $hw_server_port: ${own_pids[*]}"
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

  echo "ERROR: hw_server process(es) on port $hw_server_port did not exit after SIGTERM: ${remaining_pids[*]}" >&2
  echo "Refusing to force-kill them; another programming/debug session may be active." >&2
  echo "Stop them manually if they are stale, then retry program-cli." >&2
  exit 1
}

acquire_program_lock

foreign_hw_servers="$(find_foreign_hw_servers)"
if [ -n "$foreign_hw_servers" ]; then
  echo "ERROR: refusing to use an existing hw_server owned by another user on port $hw_server_port." >&2
  echo "Ask the owner/admin to stop it, or choose a different COYOTE_NIX_HW_SERVER_PORT/HW_SERVER_PORT." >&2
  echo >&2
  echo "Existing foreign hw_server process(es):" >&2
  printf '%s\n' "$foreign_hw_servers" >&2
  exit 1
fi

# Vivado and hw_server major versions must match. Restart any existing
# current-user hw_server on this port so this invocation uses the shell-selected version.
stop_own_hw_servers

fallback_hw_server_log="${TMPDIR:-/tmp}/hw_server-$(id -u)-$hw_server_port.log"
hw_server_log="${HW_SERVER_LOG:-}"
if [ -z "$hw_server_log" ]; then
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; then
    hw_server_log="$XDG_RUNTIME_DIR/hw_server-$hw_server_port.log"
  else
    hw_server_log="$fallback_hw_server_log"
  fi
fi
hw_server_log="$(coyote_nix_prepare_hw_server_log "$hw_server_log" "$fallback_hw_server_log")"

setsid hw_server -L- -s "tcp::$hw_server_port" >"$hw_server_log" 2>&1 &
hw_server_pid="$!"
hw_server_pgid="$hw_server_pid"
sleep 2

if ! kill -0 "$hw_server_pid" 2>/dev/null; then
  echo "ERROR: hw_server exited before programming started." >&2
  echo "hw_server log: $hw_server_log" >&2
  sed 's/^/  /' "$hw_server_log" >&2 || true
  exit 1
fi

foreign_hw_servers="$(find_foreign_hw_servers)"
if [ -n "$foreign_hw_servers" ]; then
  echo "ERROR: a foreign hw_server appeared on port $hw_server_port after starting our hw_server; refusing to continue." >&2
  echo "Existing foreign hw_server process(es):" >&2
  printf '%s\n' "$foreign_hw_servers" >&2
  exit 1
fi

tcl_file="$(mktemp /tmp/coyote_program.XXXXXX.tcl)"
cat > "$tcl_file" <<'TCL'
if {$argc < 4} {
  puts "Usage: vivado -mode batch -source <tcl> -tclargs <image> <part_hint> <hw_server_url> <jtag_target_hint>"
  exit 1
}
set image  [lindex $argv 0]
set needle [string tolower [lindex $argv 1]]
set hw_server_url [lindex $argv 2]
set target_needle [string tolower [lindex $argv 3]]

open_hw_manager
connect_hw_server -url $hw_server_url

set tgts [get_hw_targets]
if {[llength $tgts] == 0} {
  puts "No hw targets found"
  exit 3
}

set matches {}
set match_targets {}

foreach t $tgts {
  set target_lower [string tolower $t]
  if {$target_needle ne "" && [string first $target_needle $target_lower] < 0} {
    puts "Skipping target: $t (does not match FPGA_JTAG_TARGET=$target_needle)"
    continue
  }

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
  if {$target_needle ne ""} {
    puts "Target filter: FPGA_JTAG_TARGET=$target_needle"
  }
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
vivado -mode batch -log "$vivado_log" -journal "$vivado_jou" -source "$tcl_file" -tclargs "$image" "$part_hint" "$hw_server_url" "${FPGA_JTAG_TARGET:-}" &
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
