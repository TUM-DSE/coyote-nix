#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 EXPORT_CMAKE BASE_JSON OUTPUT_JSON" >&2
  exit 2
fi

export_cmake=$1
base_json=$2
output_json=$3

cmake_scalar() {
  local name=$1
  local default_value=$2
  local line
  local value
  line="$(grep -E "^set\\(${name}[[:space:]]+" "$export_cmake" | tail -n 1 || true)"
  if [[ -z $line ]]; then
    printf '%s\n' "$default_value"
    return
  fi
  value="${line#* }"
  value="${value%)}"
  value="${value#\"}"
  value="${value%\"}"
  printf '%s\n' "$value"
}

service_enabled="$(cmake_scalar EN_EXTERNAL_DYNAMIC_SERVICE 0)"
service_name="$(cmake_scalar EXTERNAL_DYNAMIC_SERVICE_NAME none)"
stream_abi="$(cmake_scalar EXTERNAL_DYNAMIC_SERVICE_ABI none)"
stream_version="$(cmake_scalar EXTERNAL_DYNAMIC_SERVICE_INTERFACE_VERSION 0)"
control_enabled="$(cmake_scalar EN_EXTERNAL_DYNAMIC_SERVICE_CONTROL 0)"
control_abi="$(cmake_scalar EXTERNAL_DYNAMIC_SERVICE_CONTROL_ABI none)"
control_version="$(cmake_scalar EXTERNAL_DYNAMIC_SERVICE_CONTROL_INTERFACE_VERSION 0)"
control_base="$(cmake_scalar EXTERNAL_DYNAMIC_SERVICE_CONTROL_BASE 0)"
control_bytes="$(cmake_scalar EXTERNAL_DYNAMIC_SERVICE_CONTROL_BYTES 0)"
control_addr_bits="$(cmake_scalar EXTERNAL_DYNAMIC_SERVICE_CONTROL_ADDR_BITS 0)"
control_data_bits="$(cmake_scalar EXTERNAL_DYNAMIC_SERVICE_CONTROL_DATA_BITS 0)"
slot_status_enabled="$(cmake_scalar EN_EXTERNAL_DYNAMIC_SERVICE_SLOT_STATUS 0)"
region_count="$(cmake_scalar N_REGIONS 0)"
streams_per_region="$(cmake_scalar N_STRM_AXI 0)"
app_interface_version="$(cmake_scalar COYOTE_APP_INTERFACE_VERSION 0)"
axi_data_bits="$(cmake_scalar COYOTE_AXI_DATA_BITS 0)"

for value in \
  "$service_enabled" "$stream_version" "$control_enabled" "$control_version" \
  "$control_base" "$control_bytes" "$control_addr_bits" "$control_data_bits" \
  "$slot_status_enabled" "$region_count" "$streams_per_region" \
  "$app_interface_version" "$axi_data_bits"; do
  if [[ ! $value =~ ^[0-9]+$ ]]; then
    echo "invalid numeric resident-service metadata value: $value" >&2
    exit 1
  fi
done
if [[ $service_enabled -gt 1 || $control_enabled -gt 1 || $slot_status_enabled -gt 1 ]]; then
  echo "resident-service enable fields must be 0 or 1" >&2
  exit 1
fi
if [[ $region_count -lt 1 || $streams_per_region -lt 1 || $axi_data_bits -lt 1 ]]; then
  echo "resident-service topology dimensions must be positive" >&2
  exit 1
fi
if [[ $slot_status_enabled -eq 1 && $service_enabled -ne 1 ]]; then
  echo "resident-service slot status cannot be enabled without the service" >&2
  exit 1
fi
if [[ $control_enabled -eq 1 && $service_enabled -ne 1 ]]; then
  echo "resident-service control cannot be enabled without the service" >&2
  exit 1
fi
if [[ $control_enabled -eq 1 && $control_abi == none ]]; then
  echo "enabled resident-service control requires a control ABI" >&2
  exit 1
fi

jq \
  --arg serviceName "$service_name" \
  --arg streamAbi "$stream_abi" \
  --arg controlAbi "$control_abi" \
  --argjson serviceEnabled "$service_enabled" \
  --argjson streamVersion "$stream_version" \
  --argjson controlEnabled "$control_enabled" \
  --argjson controlVersion "$control_version" \
  --argjson controlBase "$control_base" \
  --argjson controlBytes "$control_bytes" \
  --argjson controlAddrBits "$control_addr_bits" \
  --argjson controlDataBits "$control_data_bits" \
  --argjson slotStatusEnabled "$slot_status_enabled" \
  --argjson regionCount "$region_count" \
  --argjson streamsPerRegion "$streams_per_region" \
  --argjson appInterfaceVersion "$app_interface_version" \
  --argjson axiDataBits "$axi_data_bits" \
  '.applicationTopology = {
    regionCount: $regionCount,
    streamsPerRegion: $streamsPerRegion,
    interfaceVersion: $appInterfaceVersion,
    axiDataBits: $axiDataBits
  } | .residentService = {
    enabled: ($serviceEnabled == 1),
    name: $serviceName,
    stream: {
      abi: $streamAbi,
      interfaceVersion: $streamVersion
    },
    slotStatus: {
      enabled: ($slotStatusEnabled == 1),
      width: (if $slotStatusEnabled == 1 then $regionCount else 0 end)
    },
    control: {
      enabled: ($controlEnabled == 1),
      abi: $controlAbi,
      interfaceVersion: $controlVersion,
      base: $controlBase,
      bytes: $controlBytes,
      addressBits: $controlAddrBits,
      dataBits: $controlDataBits
    }
  }' \
  "$base_json" > "$output_json"
