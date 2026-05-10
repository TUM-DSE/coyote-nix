count="${1:-${COYOTE_HUGEPAGES:-1024}}"
sudo sysctl -w "vm.nr_hugepages=$count"
