#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/nix/tools/add-coprocessor-metadata.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf '{"schemaVersion":1}\n' >"$tmp/base.json"
cat >"$tmp/enabled.cmake" <<'EOF'
set(COPROCESSOR_INTERFACE_PRESENT 1)
set(N_COPROCESSOR_PORTS 2)
set(COPROCESSOR_INTERFACE_VERSION 1)
set(COPROCESSOR_STREAM_ABI 1)
set(COPROCESSOR_STREAM_DATA_BITS 512)
set(COPROCESSOR_STREAM_ID_BITS 6)
set(COPROCESSOR_MAX_PACKET_BYTES 4096)
set(COPROCESSOR_MMIO_ABI 1)
set(COPROCESSOR_MMIO_ADDR_BITS 12)
set(COPROCESSOR_MMIO_DATA_BITS 64)
set(COPROCESSOR_BINDING_GENERATION_BITS 32)
set(COPROCESSOR_PROVIDER_COUNT 2)
set(COPROCESSOR_PROVIDER_DESCRIPTORS "1|mock-r5|r5|baremetal|runtime|1|1|1|1|100;2|mock-a72|a72|baremetal|runtime|1|1|1|1|80")
EOF
bash "$script" "$tmp/enabled.cmake" "$tmp/base.json" "$tmp/enabled.json"
jq -e '
  .coprocessor.enabled == true
  and .coprocessor.logicalPortCount == 2
  and .coprocessor.stream == {
    abi: 1, dataBits: 512, idBits: 6, maxPacketBytes: 4096, packetAtomic: true
  }
  and .coprocessor.mmio == {
    abi: 1, addressBits: 12, dataBits: 64, maxOutstanding: 1
  }
  and .coprocessor.providers[0].processorClass == "r5"
  and .coprocessor.providers[1].processorClass == "a72"
  and .coprocessor.providers[0].timingNs == 100
' "$tmp/enabled.json" >/dev/null

: >"$tmp/disabled.cmake"
bash "$script" "$tmp/disabled.cmake" "$tmp/base.json" "$tmp/disabled.json"
jq -e '
  .coprocessor.enabled == false
  and .coprocessor.logicalPortCount == 0
  and .coprocessor.interfaceVersion == 0
  and .coprocessor.stream.dataBits == 0
  and .coprocessor.mmio.dataBits == 0
  and .coprocessor.providers == []
' "$tmp/disabled.json" >/dev/null

printf 'set(COPROCESSOR_STREAM_ABI 1)\n' >"$tmp/contradictory-disabled.cmake"
if bash "$script" "$tmp/contradictory-disabled.cmake" "$tmp/base.json" "$tmp/bad.json"; then
  echo "contradictory disabled metadata unexpectedly accepted" >&2
  exit 1
fi

sed 's/set(COPROCESSOR_PROVIDER_COUNT 2)/set(COPROCESSOR_PROVIDER_COUNT 3)/' \
  "$tmp/enabled.cmake" >"$tmp/bad-count.cmake"
if bash "$script" "$tmp/bad-count.cmake" "$tmp/base.json" "$tmp/bad.json"; then
  echo "provider count mismatch unexpectedly accepted" >&2
  exit 1
fi

sed 's/;2|mock-a72|a72|baremetal|runtime|1|1|1|1|80/;1|mock-a72|a72|baremetal|runtime|1|1|1|1|80/' \
  "$tmp/enabled.cmake" >"$tmp/duplicate.cmake"
if bash "$script" "$tmp/duplicate.cmake" "$tmp/base.json" "$tmp/bad.json"; then
  echo "duplicate endpoint unexpectedly accepted" >&2
  exit 1
fi
