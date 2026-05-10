usage() {
  echo "Usage: set-hugepages [count]" >&2
  echo "Set vm.nr_hugepages. Defaults to COYOTE_HUGEPAGES or 1024." >&2
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

count="${1:-${COYOTE_HUGEPAGES:-1024}}"
sudo sysctl -w "vm.nr_hugepages=$count"
