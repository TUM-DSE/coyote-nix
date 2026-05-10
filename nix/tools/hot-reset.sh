bdf="${1:-${FPGA_BDF:-}}"
reset_hold_s="${COYOTE_NIX_HOT_RESET_HOLD_S:-0.5}"
post_reset_settle_s="${COYOTE_NIX_HOT_RESET_SETTLE_S:-2}"
ready_timeout_s="${COYOTE_NIX_HOT_RESET_READY_TIMEOUT_S:-30}"
ready_poll_s="${COYOTE_NIX_HOT_RESET_READY_POLL_S:-0.2}"
# A secondary-bus hot reset is not always enough after FPGA reprogramming:
# Linux can keep stale endpoint/BAR state and the Coyote driver then reads bogus
# XDMA registers.  By default, remove and rescan the endpoint after reset so the
# kernel rediscovers the just-programmed PCIe image.  Set to 0/false/no to keep
# the old pure-hot-reset behavior.
pci_rescan="${COYOTE_NIX_HOT_RESET_PCI_RESCAN:-1}"
rescan_settle_s="${COYOTE_NIX_HOT_RESET_RESCAN_SETTLE_S:-2}"

dev="$bdf"
if [ -z "$dev" ]; then
  echo "ERROR: missing BDF. Pass it as argument or set FPGA_BDF." >&2
  exit 1
fi

if [ ! -e "/sys/bus/pci/devices/$dev" ]; then
  dev="0000:$dev"
fi

if [ ! -e "/sys/bus/pci/devices/$dev" ]; then
  echo "ERROR: device $dev not found" >&2
  exit 1
fi

if ! command -v setpci >/dev/null 2>&1; then
  echo "ERROR: setpci is required for bridge-level hot reset." >&2
  exit 1
fi

port="$(basename "$(dirname "$(readlink "/sys/bus/pci/devices/$dev")")")"
if [ ! -e "/sys/bus/pci/devices/$port" ]; then
  echo "ERROR: upstream port $port not found" >&2
  exit 1
fi

read_cfg_word() {
  local bdf_word="$1"
  local reg="$2"
  sudo setpci -s "$bdf_word" "$reg" 2>/dev/null | tr -d '[:space:]'
}

wait_for_endpoint_ready() {
  local deadline now vendor_id context="${1:-hot reset}"
  deadline=$(( $(date +%s) + ready_timeout_s ))

  while :; do
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "ERROR: endpoint $dev did not become config-space-ready within ${ready_timeout_s}s after $context" >&2
      return 1
    fi

    vendor_id="$(read_cfg_word "$dev" VENDOR_ID || true)"
    case "$vendor_id" in
      [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
        if [ "$vendor_id" != "ffff" ] && [ "$vendor_id" != "0000" ]; then
          sleep "$post_reset_settle_s"
          return 0
        fi
        ;;
    esac

    sleep "$ready_poll_s"
  done
}

wait_for_endpoint_in_sysfs() {
  local deadline now context="${1:-PCI rescan}"
  deadline=$(( $(date +%s) + ready_timeout_s ))

  while :; do
    if [ -e "/sys/bus/pci/devices/$dev" ]; then
      return 0
    fi

    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      echo "ERROR: endpoint $dev did not reappear in sysfs within ${ready_timeout_s}s after $context" >&2
      return 1
    fi

    sleep "$ready_poll_s"
  done
}

pci_rescan_enabled() {
  case "$pci_rescan" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off) return 1 ;;
    *) return 0 ;;
  esac
}

remove_and_rescan_endpoint() {
  echo "Removing endpoint $dev from Linux PCI tree and rescanning..."

  if [ ! -e "/sys/bus/pci/devices/$dev/remove" ]; then
    echo "ERROR: /sys/bus/pci/devices/$dev/remove is not available" >&2
    return 1
  fi

  echo 1 | sudo tee "/sys/bus/pci/devices/$dev/remove" >/dev/null
  sleep 1
  echo 1 | sudo tee /sys/bus/pci/rescan >/dev/null

  wait_for_endpoint_in_sysfs "PCI rescan"
  wait_for_endpoint_ready "PCI rescan"
  sleep "$rescan_settle_s"
}

orig_bridge_control="$(read_cfg_word "$port" BRIDGE_CONTROL)"
if [ -z "$orig_bridge_control" ]; then
  echo "ERROR: failed to read BRIDGE_CONTROL for upstream port $port" >&2
  exit 1
fi

case "$orig_bridge_control" in
  [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
  *)
    echo "ERROR: unexpected BRIDGE_CONTROL value for $port: $orig_bridge_control" >&2
    exit 1
    ;;
esac

asserted_bridge_control="$(printf '%04x' "$((0x$orig_bridge_control | 0x0040))")"

echo "Secondary-bus hot reset via upstream bridge $port for endpoint $dev..."
echo "Hold=${reset_hold_s}s settle=${post_reset_settle_s}s ready-timeout=${ready_timeout_s}s pci-rescan=${pci_rescan}"
sudo setpci -s "$port" BRIDGE_CONTROL="$asserted_bridge_control"
sleep "$reset_hold_s"
sudo setpci -s "$port" BRIDGE_CONTROL="$orig_bridge_control"

echo "Restored BRIDGE_CONTROL=$orig_bridge_control on $port"
wait_for_endpoint_ready "hot reset"

if pci_rescan_enabled; then
  remove_and_rescan_endpoint
fi

echo "Endpoint $dev is config-space-ready again"
