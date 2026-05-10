if [ $# -gt 1 ]; then
  echo "Usage: program-cli [image.bit|image.pdi]" >&2
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
}

trap cleanup_program_cli EXIT
trap 'exit 130' INT TERM

# Vivado and hw_server major versions must match. Restart any existing user-owned
# hw_server so this invocation uses the shell-selected version.
existing_hw_server_pids="$(pgrep -u "$(id -u)" -x hw_server || true)"
if [ -n "$existing_hw_server_pids" ]; then
  echo "Stopping existing hw_server process(es): $existing_hw_server_pids"
  # shellcheck disable=SC2086
  kill $existing_hw_server_pids 2>/dev/null || true
  sleep 1
fi

hw_server -s tcp::3121 >/tmp/hw_server.log 2>&1 &
hw_server_pid="$!"
sleep 2

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
