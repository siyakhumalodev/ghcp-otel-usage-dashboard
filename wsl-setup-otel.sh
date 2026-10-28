#!/usr/bin/env bash

# OpenTelemetry environment setup for WSL.
#
# Purpose:
# - Copilot telemetry often needs extra metadata that is not present in the raw chat messages.
# - This script captures that missing context, including squad and product ownership, so telemetry can be attributed more usefully.
# - It sets OpenTelemetry environment variables that VS Code telemetry can pick up and inject into exported data.
# - The variables must exist before VS Code starts, because telemetry only reads the environment that is already present when the editor launches.
#
# What it sets:
# - OTEL_EXPORTER_OTLP_ENDPOINT: collector endpoint for telemetry export
# - OTEL_EXPORTER_OTLP_PROTOCOL: OTLP transport used by VS Code
# - OTEL_RESOURCE_ATTRIBUTES: additional metadata such as org.squad and org.product

set -euo pipefail

DEFAULT_COLLECTOR_ENDPOINT=""
DEFAULT_OTLP_PROTOCOL="otlp-http"

trim_whitespace() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

prompt_with_default() {
  local prompt_text="$1"
  local default_value="$2"
  local response=""

  if [[ -n "$default_value" ]]; then
    read -rp "$prompt_text [$default_value]: " response
    response="$(trim_whitespace "$response")"
    printf '%s' "${response:-$default_value}"
  else
    read -rp "$prompt_text: " response
    printf '%s' "$(trim_whitespace "$response")"
  fi
}

confirm() {
  local prompt_text="$1"
  local response=""

  while true; do
    read -rp "$prompt_text [Y/n]: " response
    response="$(trim_whitespace "$response")"
    case "${response,,}" in
      ""|y|yes)
        return 0
        ;;
      n|no)
        return 1
        ;;
      *)
        echo "Please answer y or n." >&2
        ;;
    esac
  done
}

escape_resource_attribute_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//,/\\,}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

build_resource_attributes() {
  local squad="$1"
  local product="$2"
  local parts=()

  if [[ -n "$squad" ]]; then
    parts+=("org.squad=$(escape_resource_attribute_value "$squad")")
  fi

  if [[ -n "$product" ]]; then
    parts+=("org.product=$(escape_resource_attribute_value "$product")")
  fi

  (IFS=,; printf '%s' "${parts[*]}")
}

main() {
  local collector_endpoint=""
  local squad_name=""
  local product_name=""
  local resource_attributes=""

  echo "OpenTelemetry environment setup for WSL"

  collector_endpoint=$(prompt_with_default "Collector endpoint" "${OTEL_EXPORTER_OTLP_ENDPOINT:-$DEFAULT_COLLECTOR_ENDPOINT}")
  if [[ -z "$collector_endpoint" ]]; then
    echo "Collector endpoint is required." >&2
    return 1
  fi
  squad_name=$(prompt_with_default "Squad name" "${OTEL_RESOURCE_ATTRIBUTE_SQUAD:-${SQUAD_NAME:-}}")
  product_name=$(prompt_with_default "Product name" "${OTEL_RESOURCE_ATTRIBUTE_PRODUCT:-${PRODUCT_NAME:-}}")

  resource_attributes="$(build_resource_attributes "$squad_name" "$product_name")"

  echo
  echo "Proposed values:"
  echo "  OTEL_EXPORTER_OTLP_ENDPOINT=$collector_endpoint"
  echo "  OTEL_EXPORTER_OTLP_PROTOCOL=$DEFAULT_OTLP_PROTOCOL"
  echo "  OTEL_RESOURCE_ATTRIBUTES=$resource_attributes"
  echo

  if ! confirm "Apply these values to the current shell?"; then
    echo "Aborted." >&2
    return 1
  fi

  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cat <<EOF
export OTEL_EXPORTER_OTLP_ENDPOINT=$(printf '%q' "$collector_endpoint")
export OTEL_EXPORTER_OTLP_PROTOCOL=$(printf '%q' "$DEFAULT_OTLP_PROTOCOL")
export OTEL_RESOURCE_ATTRIBUTES=$(printf '%q' "$resource_attributes")
EOF
    echo "Run this script with source to apply the variables in your current shell:" >&2
    echo "  source ./wsl-setup-otel.sh" >&2
  else
    export OTEL_EXPORTER_OTLP_ENDPOINT="$collector_endpoint"
    export OTEL_EXPORTER_OTLP_PROTOCOL="$DEFAULT_OTLP_PROTOCOL"
    export OTEL_RESOURCE_ATTRIBUTES="$resource_attributes"

    echo "Applied environment variables to the current shell." >&2
    echo "OTEL_EXPORTER_OTLP_ENDPOINT=$OTEL_EXPORTER_OTLP_ENDPOINT" >&2
    echo "OTEL_EXPORTER_OTLP_PROTOCOL=$OTEL_EXPORTER_OTLP_PROTOCOL" >&2
    echo "OTEL_RESOURCE_ATTRIBUTES=$OTEL_RESOURCE_ATTRIBUTES" >&2
  fi
}

main "$@"