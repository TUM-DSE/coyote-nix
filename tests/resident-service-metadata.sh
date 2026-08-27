#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf '{"schemaVersion":1}\n' > "$tmp/base.json"
cat > "$tmp/control.cmake" <<'EOF'
set(EN_EXTERNAL_DYNAMIC_SERVICE 1)
set(EXTERNAL_DYNAMIC_SERVICE_NAME "fixture-service")
set(EXTERNAL_DYNAMIC_SERVICE_ABI "fixture-stream-v1")
set(EXTERNAL_DYNAMIC_SERVICE_INTERFACE_VERSION 1)
set(EN_EXTERNAL_DYNAMIC_SERVICE_CONTROL 1)
set(EXTERNAL_DYNAMIC_SERVICE_CONTROL_ABI "fixture-control-v1")
set(EXTERNAL_DYNAMIC_SERVICE_CONTROL_INTERFACE_VERSION 1)
set(EXTERNAL_DYNAMIC_SERVICE_CONTROL_BASE 4096)
set(EXTERNAL_DYNAMIC_SERVICE_CONTROL_BYTES 4096)
set(EXTERNAL_DYNAMIC_SERVICE_CONTROL_ADDR_BITS 12)
set(EXTERNAL_DYNAMIC_SERVICE_CONTROL_DATA_BITS 64)
set(EN_EXTERNAL_DYNAMIC_SERVICE_SLOT_STATUS 1)
set(EN_EXTERNAL_DYNAMIC_SERVICE_PEER_ENDPOINTS 1)
set(EXTERNAL_DYNAMIC_SERVICE_PEER_INTERFACE_VERSION 1)
set(EN_PEER 1)
set(PEER_BACKEND "aurora_qsfp1")
set(PEER_CONNECTOR "QSFP1")
set(PEER_FLOW_CONTROL_MODE "aurora-immediate-nfc")
set(COYOTE_PEER_INTERFACE_VERSION 1)
set(N_PEER_LINKS 1)
set(N_PEER_AXI 1)
set(N_REGIONS 2)
set(N_STRM_AXI 1)
set(N_HOST_STRM_AXI 1)
set(COYOTE_APP_INTERFACE_VERSION 1)
set(COYOTE_AXI_DATA_BITS 512)
EOF

bash "$repo_root/nix/tools/add-resident-service-metadata.sh" \
  "$tmp/control.cmake" "$tmp/base.json" "$tmp/control.json"
jq -e '
  .applicationTopology == {
    regionCount: 2,
    streamsPerRegion: 1,
    hostStreamsPerRegion: 1,
    interfaceVersion: 1,
    axiDataBits: 512
  }
  and .residentService == {
    enabled: true,
    name: "fixture-service",
    stream: {abi: "fixture-stream-v1", interfaceVersion: 1},
    slotStatus: {enabled: true, width: 2},
    peerEndpoints: {enabled: true, interfaceVersion: 1, count: 1},
    control: {
      enabled: true,
      abi: "fixture-control-v1",
      interfaceVersion: 1,
      base: 4096,
      bytes: 4096,
      addressBits: 12,
      dataBits: 64
    }
  }
  and .peerTransport == {
    enabled: true,
    backend: "aurora_qsfp1",
    connector: "QSFP1",
    flowControl: "aurora-immediate-nfc",
    owner: "resident-service",
    interfaceVersion: 1,
    links: 1,
    endpoints: 1,
    streamBits: 512,
    backpressure: "aurora-immediate-nfc"
  }
' "$tmp/control.json" >/dev/null

cat > "$tmp/legacy.cmake" <<'EOF'
set(EN_EXTERNAL_DYNAMIC_SERVICE 0)
set(EXTERNAL_DYNAMIC_SERVICE_NAME "none")
set(EXTERNAL_DYNAMIC_SERVICE_ABI "none")
set(EXTERNAL_DYNAMIC_SERVICE_INTERFACE_VERSION 1)
set(EN_EXTERNAL_DYNAMIC_SERVICE_SLOT_STATUS 0)
set(N_REGIONS 1)
set(N_STRM_AXI 1)
set(COYOTE_APP_INTERFACE_VERSION 1)
set(COYOTE_AXI_DATA_BITS 512)
EOF
bash "$repo_root/nix/tools/add-resident-service-metadata.sh" \
  "$tmp/legacy.cmake" "$tmp/base.json" "$tmp/legacy.json"
jq -e '
  .applicationTopology.regionCount == 1
  and .residentService.enabled == false
  and .applicationTopology.hostStreamsPerRegion == 1
  and .residentService.slotStatus == {enabled: false, width: 0}
  and .residentService.peerEndpoints.enabled == false
  and .residentService.control.enabled == false
  and .peerTransport.enabled == false
  and .residentService.control.bytes == 0
' "$tmp/legacy.json" >/dev/null

sed 's/set(EN_EXTERNAL_DYNAMIC_SERVICE 1)/set(EN_EXTERNAL_DYNAMIC_SERVICE 0)/' \
  "$tmp/control.cmake" > "$tmp/malformed.cmake"
if bash "$repo_root/nix/tools/add-resident-service-metadata.sh" \
  "$tmp/malformed.cmake" "$tmp/base.json" "$tmp/malformed.json"; then
  echo "malformed control metadata unexpectedly succeeded" >&2
  exit 1
fi

sed '/set(PEER_FLOW_CONTROL_MODE/d' "$tmp/control.cmake" > "$tmp/malformed-peer.cmake"
if bash "$repo_root/nix/tools/add-resident-service-metadata.sh" \
  "$tmp/malformed-peer.cmake" "$tmp/base.json" "$tmp/malformed-peer.json"; then
  echo "peer metadata without flow-control mode unexpectedly succeeded" >&2
  exit 1
fi
