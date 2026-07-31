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
EOF

bash "$repo_root/nix/tools/add-resident-service-metadata.sh" \
  "$tmp/control.cmake" "$tmp/base.json" "$tmp/control.json"
jq -e '
  .residentService == {
    enabled: true,
    name: "fixture-service",
    stream: {abi: "fixture-stream-v1", interfaceVersion: 1},
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
' "$tmp/control.json" >/dev/null

cat > "$tmp/legacy.cmake" <<'EOF'
set(EN_EXTERNAL_DYNAMIC_SERVICE 0)
set(EXTERNAL_DYNAMIC_SERVICE_NAME "none")
set(EXTERNAL_DYNAMIC_SERVICE_ABI "none")
set(EXTERNAL_DYNAMIC_SERVICE_INTERFACE_VERSION 1)
EOF
bash "$repo_root/nix/tools/add-resident-service-metadata.sh" \
  "$tmp/legacy.cmake" "$tmp/base.json" "$tmp/legacy.json"
jq -e '
  .residentService.enabled == false
  and .residentService.control.enabled == false
  and .residentService.control.bytes == 0
' "$tmp/legacy.json" >/dev/null

sed 's/set(EN_EXTERNAL_DYNAMIC_SERVICE 1)/set(EN_EXTERNAL_DYNAMIC_SERVICE 0)/' \
  "$tmp/control.cmake" > "$tmp/malformed.cmake"
if bash "$repo_root/nix/tools/add-resident-service-metadata.sh" \
  "$tmp/malformed.cmake" "$tmp/base.json" "$tmp/malformed.json"; then
  echo "malformed control metadata unexpectedly succeeded" >&2
  exit 1
fi
