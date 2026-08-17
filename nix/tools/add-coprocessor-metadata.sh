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

interface_present="$(cmake_scalar COPROCESSOR_INTERFACE_PRESENT 0)"
port_count="$(cmake_scalar N_COPROCESSOR_PORTS 0)"
interface_version="$(cmake_scalar COPROCESSOR_INTERFACE_VERSION 0)"
stream_abi="$(cmake_scalar COPROCESSOR_STREAM_ABI 0)"
stream_data_bits="$(cmake_scalar COPROCESSOR_STREAM_DATA_BITS 0)"
stream_id_bits="$(cmake_scalar COPROCESSOR_STREAM_ID_BITS 0)"
max_packet_bytes="$(cmake_scalar COPROCESSOR_MAX_PACKET_BYTES 0)"
mmio_abi="$(cmake_scalar COPROCESSOR_MMIO_ABI 0)"
mmio_addr_bits="$(cmake_scalar COPROCESSOR_MMIO_ADDR_BITS 0)"
mmio_data_bits="$(cmake_scalar COPROCESSOR_MMIO_DATA_BITS 0)"
generation_bits="$(cmake_scalar COPROCESSOR_BINDING_GENERATION_BITS 0)"
provider_count="$(cmake_scalar COPROCESSOR_PROVIDER_COUNT 0)"
provider_descriptors="$(cmake_scalar COPROCESSOR_PROVIDER_DESCRIPTORS '')"

for value in \
  "$interface_present" "$port_count" "$interface_version" "$stream_abi" "$stream_data_bits" \
  "$stream_id_bits" "$max_packet_bytes" "$mmio_abi" "$mmio_addr_bits" \
  "$mmio_data_bits" "$generation_bits" "$provider_count"; do
  if [[ ! $value =~ ^[0-9]+$ ]]; then
    echo "invalid numeric co-processor metadata value: $value" >&2
    exit 1
  fi
done
if [[ $interface_present -gt 1 ]]; then
  echo "co-processor interface-present field must be 0 or 1" >&2
  exit 1
fi
if [[ $port_count -eq 0 ]]; then
  if [[ $interface_present -ne 0 || $provider_count -ne 0 || $interface_version -ne 0 || $stream_abi -ne 0 ||
        $stream_data_bits -ne 0 || $stream_id_bits -ne 0 || $max_packet_bytes -ne 0 ||
        $mmio_abi -ne 0 || $mmio_addr_bits -ne 0 || $mmio_data_bits -ne 0 ||
        $generation_bits -ne 0 || -n $provider_descriptors ]]; then
    echo "disabled co-processor metadata must have zero dimensions and no providers" >&2
    exit 1
  fi
fi
if [[ $port_count -gt 0 ]]; then
  if [[ $interface_present -ne 1 ]]; then
    echo "enabled co-processor metadata requires a complete interface marker" >&2
    exit 1
  fi
  for value in \
    "$interface_version" "$stream_abi" "$stream_data_bits" "$stream_id_bits" \
    "$max_packet_bytes" "$mmio_abi" "$mmio_addr_bits" "$mmio_data_bits" \
    "$generation_bits"; do
    if [[ $value -eq 0 ]]; then
      echo "enabled co-processor dimensions and ABIs must be nonzero" >&2
      exit 1
    fi
  done
fi

providers='[]'
actual_count=0
if [[ -n $provider_descriptors ]]; then
  IFS=';' read -r -a descriptors <<<"$provider_descriptors"
  for descriptor in "${descriptors[@]}"; do
    [[ -n $descriptor ]] || continue
    IFS='|' read -r endpoint name processor_class runtime_abi firmware_abi provider_stream_abi provider_mmio_abi generation capacity timing_ns extra <<<"$descriptor"
    if [[ -n ${extra:-} || -z ${timing_ns:-} ]]; then
      echo "malformed co-processor provider descriptor: $descriptor" >&2
      exit 1
    fi
    if [[ -z $name || -z $processor_class || -z $runtime_abi || -z $firmware_abi ]]; then
      echo "co-processor provider identity fields must be nonempty" >&2
      exit 1
    fi
    for value in "$endpoint" "$provider_stream_abi" "$provider_mmio_abi" "$generation" "$capacity"; do
      if [[ ! $value =~ ^[1-9][0-9]*$ ]]; then
        echo "invalid co-processor provider numeric value: $value" >&2
        exit 1
      fi
    done
    if jq -e --argjson endpoint "$endpoint" 'any(.[]; .endpointId == $endpoint)' <<<"$providers" >/dev/null; then
      echo "duplicate co-processor provider endpoint: $endpoint" >&2
      exit 1
    fi
    if [[ ! $timing_ns =~ ^[0-9]+$ ]]; then
      echo "invalid co-processor provider timing value: $timing_ns" >&2
      exit 1
    fi
    providers="$(
      jq -c \
        --argjson endpointId "$endpoint" \
        --arg name "$name" \
        --arg processorClass "$processor_class" \
        --arg runtimeAbi "$runtime_abi" \
        --arg firmwareAbi "$firmware_abi" \
        --argjson providerStreamAbi "$provider_stream_abi" \
        --argjson providerMmioAbi "$provider_mmio_abi" \
        --argjson generation "$generation" \
        --argjson capacity "$capacity" \
        --argjson timingNs "$timing_ns" \
        '. + [{
          endpointId: $endpointId,
          name: $name,
          processorClass: $processorClass,
          runtimeAbi: $runtimeAbi,
          firmwareAbi: $firmwareAbi,
          streamAbi: $providerStreamAbi,
          mmioAbi: $providerMmioAbi,
          generation: $generation,
          capacity: $capacity,
          timingNs: $timingNs
        }]' <<<"$providers"
    )"
    actual_count=$((actual_count + 1))
  done
fi
if [[ $actual_count -ne $provider_count ]]; then
  echo "co-processor provider count mismatch: declared $provider_count, found $actual_count" >&2
  exit 1
fi

jq \
  --argjson portCount "$port_count" \
  --argjson interfaceVersion "$interface_version" \
  --argjson streamAbi "$stream_abi" \
  --argjson streamDataBits "$stream_data_bits" \
  --argjson streamIdBits "$stream_id_bits" \
  --argjson maxPacketBytes "$max_packet_bytes" \
  --argjson mmioAbi "$mmio_abi" \
  --argjson mmioAddressBits "$mmio_addr_bits" \
  --argjson mmioDataBits "$mmio_data_bits" \
  --argjson generationBits "$generation_bits" \
  --argjson providers "$providers" \
  '.coprocessor = {
    enabled: ($portCount > 0),
    logicalPortCount: $portCount,
    interfaceVersion: $interfaceVersion,
    stream: {
      abi: $streamAbi,
      dataBits: $streamDataBits,
      idBits: $streamIdBits,
      maxPacketBytes: $maxPacketBytes,
      packetAtomic: true
    },
    mmio: {
      abi: $mmioAbi,
      addressBits: $mmioAddressBits,
      dataBits: $mmioDataBits,
      maxOutstanding: 1
    },
    status: {
      bindingGenerationBits: $generationBits
    },
    providers: $providers
  }' "$base_json" >"$output_json"
