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
peer_enabled="$(cmake_scalar EN_PEER 0)"
peer_backend="$(cmake_scalar PEER_BACKEND none)"
peer_connector="$(cmake_scalar PEER_CONNECTOR none)"
peer_flow_control="$(cmake_scalar PEER_FLOW_CONTROL_MODE none)"
peer_links="$(cmake_scalar N_PEER_LINKS 0)"
peer_endpoints="$(cmake_scalar N_PEER_AXI 0)"
peer_service_owned="$(cmake_scalar EN_EXTERNAL_DYNAMIC_SERVICE_PEER_ENDPOINTS 0)"
peer_interface_version="$(cmake_scalar COYOTE_PEER_INTERFACE_VERSION 0)"
resident_peer_interface_version="$(cmake_scalar EXTERNAL_DYNAMIC_SERVICE_PEER_INTERFACE_VERSION 0)"
region_count="$(cmake_scalar N_REGIONS 0)"
streams_per_region="$(cmake_scalar N_STRM_AXI 0)"
host_streams_per_region="$(cmake_scalar N_HOST_STRM_AXI "$streams_per_region")"
app_interface_version="$(cmake_scalar COYOTE_APP_INTERFACE_VERSION 0)"
axi_data_bits="$(cmake_scalar COYOTE_AXI_DATA_BITS 0)"

for value in \
  "$service_enabled" "$stream_version" "$control_enabled" "$control_version" \
  "$control_base" "$control_bytes" "$control_addr_bits" "$control_data_bits" \
  "$slot_status_enabled" "$peer_enabled" "$peer_links" "$peer_endpoints" \
  "$peer_service_owned" "$peer_interface_version" \
  "$resident_peer_interface_version" "$region_count" \
  "$streams_per_region" "$host_streams_per_region" \
  "$app_interface_version" "$axi_data_bits"; do
  if [[ ! $value =~ ^[0-9]+$ ]]; then
    echo "invalid numeric resident-service metadata value: $value" >&2
    exit 1
  fi
done
if [[ $service_enabled -gt 1 || $control_enabled -gt 1 || $slot_status_enabled -gt 1 ||
      $peer_enabled -gt 1 || $peer_service_owned -gt 1 ]]; then
  echo "resident-service and peer enable fields must be 0 or 1" >&2
  exit 1
fi
if [[ $region_count -lt 1 || $streams_per_region -lt 1 ||
      $host_streams_per_region -lt 1 || $axi_data_bits -lt 1 ]]; then
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
if [[ $peer_enabled -eq 1 ]]; then
  if [[ $peer_backend == none || $peer_connector == none ||
        $peer_flow_control == none || $peer_interface_version -lt 1 ||
        $peer_links -lt 1 || $peer_endpoints -lt 1 ]]; then
    echo "enabled peer transport requires an interface version, backend, connector, flow-control mode, link, and endpoint" >&2
    exit 1
  fi
elif [[ $peer_service_owned -eq 1 ]]; then
  echo "resident-service peer ownership requires peer transport" >&2
  exit 1
fi
if [[ $peer_service_owned -eq 1 && $service_enabled -ne 1 ]]; then
  echo "resident-service peer ownership requires the resident service" >&2
  exit 1
fi
if [[ $peer_service_owned -eq 1 &&
      $resident_peer_interface_version -ne $peer_interface_version ]]; then
  echo "resident-service and generic peer interface versions must match" >&2
  exit 1
fi

jq \
  --arg serviceName "$service_name" \
  --arg streamAbi "$stream_abi" \
  --arg controlAbi "$control_abi" \
  --arg peerBackend "$peer_backend" \
  --arg peerConnector "$peer_connector" \
  --arg peerFlowControl "$peer_flow_control" \
  --argjson serviceEnabled "$service_enabled" \
  --argjson streamVersion "$stream_version" \
  --argjson controlEnabled "$control_enabled" \
  --argjson controlVersion "$control_version" \
  --argjson controlBase "$control_base" \
  --argjson controlBytes "$control_bytes" \
  --argjson controlAddrBits "$control_addr_bits" \
  --argjson controlDataBits "$control_data_bits" \
  --argjson slotStatusEnabled "$slot_status_enabled" \
  --argjson peerEnabled "$peer_enabled" \
  --argjson peerLinks "$peer_links" \
  --argjson peerEndpoints "$peer_endpoints" \
  --argjson peerServiceOwned "$peer_service_owned" \
  --argjson peerInterfaceVersion "$peer_interface_version" \
  --argjson residentPeerInterfaceVersion "$resident_peer_interface_version" \
  --argjson regionCount "$region_count" \
  --argjson streamsPerRegion "$streams_per_region" \
  --argjson hostStreamsPerRegion "$host_streams_per_region" \
  --argjson appInterfaceVersion "$app_interface_version" \
  --argjson axiDataBits "$axi_data_bits" \
  '.applicationTopology = {
    regionCount: $regionCount,
    streamsPerRegion: $streamsPerRegion,
    hostStreamsPerRegion: $hostStreamsPerRegion,
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
    peerEndpoints: {
      enabled: ($peerServiceOwned == 1),
      interfaceVersion: $residentPeerInterfaceVersion,
      count: (if $peerServiceOwned == 1 then $peerEndpoints else 0 end)
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
  } | .peerTransport = {
    enabled: ($peerEnabled == 1),
    backend: $peerBackend,
    connector: $peerConnector,
    flowControl: $peerFlowControl,
    owner: (if $peerEnabled != 1 then "none" elif $peerServiceOwned == 1 then "resident-service" else "application" end),
    interfaceVersion: $peerInterfaceVersion,
    links: (if $peerEnabled == 1 then $peerLinks else 0 end),
    endpoints: (if $peerEnabled == 1 then $peerEndpoints else 0 end),
    streamBits: $axiDataBits,
    backpressure: $peerFlowControl
  }' \
  "$base_json" > "$output_json"
