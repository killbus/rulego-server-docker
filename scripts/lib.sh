#!/usr/bin/env bash

set -Eeuo pipefail

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

require_command() {
  local command_name
  for command_name in "$@"; do
    command -v "${command_name}" >/dev/null 2>&1 || die "required command not found: ${command_name}"
  done
}

require_positive_integer() {
  local name=${1:?name is required}
  local value=${2-}
  [[ ${value} =~ ^[1-9][0-9]*$ ]] || die "${name} must be a positive integer"
}

validate_version() {
  local version=${1:?version is required}
  [[ ${version} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must match vMAJOR.MINOR.PATCH: ${version}"
}

next_retry_delay() {
  local delay=${1:?delay is required}
  local maximum=${2:?maximum is required}
  if ((delay >= maximum || delay * 2 > maximum)); then
    printf '%s\n' "${maximum}"
  else
    printf '%s\n' "$((delay * 2))"
  fi
}

is_transient_curl_exit() {
  case ${1:?curl exit status is required} in
    # DNS/connect/TLS failures, partial or empty responses, timeouts, send or
    # receive failures, and HTTP/2 stream errors are safe to retry for GETs.
    5 | 6 | 7 | 16 | 18 | 28 | 35 | 52 | 55 | 56 | 92)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_transient_http_response() {
  local status=${1:?HTTP status is required}
  local headers=${2:?header file is required}
  local body=${3:?body file is required}

  case ${status} in
    408 | 425 | 429 | 5??)
      return 0
      ;;
    403)
      # GitHub uses 403 as well as 429 when an API rate limit is exhausted.
      grep -Eiq '^(retry-after:[[:space:]]*[0-9]+|x-ratelimit-remaining:[[:space:]]*0)[[:space:]]*$' "${headers}" \
        || grep -Eiq 'rate limit|rate-limit' "${body}"
      ;;
    *)
      return 1
      ;;
  esac
}

http_get_with_retry() {
  local output=${1:?output path is required}
  local request_timeout=${2:?request timeout is required}
  local url=${3:?URL is required}
  shift 3

  local attempts=${HTTP_RETRY_ATTEMPTS:-8}
  local delay=${HTTP_RETRY_INITIAL_DELAY:-2}
  local max_delay=${HTTP_RETRY_MAX_DELAY:-30}
  require_positive_integer HTTP_RETRY_ATTEMPTS "${attempts}"
  require_positive_integer HTTP_RETRY_INITIAL_DELAY "${delay}"
  require_positive_integer HTTP_RETRY_MAX_DELAY "${max_delay}"

  local output_dir temporary_body temporary_headers
  output_dir=$(dirname -- "${output}")
  mkdir -p -- "${output_dir}"
  temporary_body=$(mktemp "${output_dir}/.http-body.XXXXXX")
  temporary_headers=$(mktemp "${output_dir}/.http-headers.XXXXXX")

  local attempt curl_status http_status retry_reason
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    : >"${temporary_headers}"
    http_status=
    if http_status=$(curl \
      --silent \
      --show-error \
      --location \
      --connect-timeout 15 \
      --max-time "${request_timeout}" \
      --dump-header "${temporary_headers}" \
      --output "${temporary_body}" \
      --write-out '%{http_code}' \
      "$@" \
      "${url}"); then
      curl_status=0
    else
      curl_status=$?
    fi

    if ((curl_status == 0)) && [[ ${http_status} =~ ^2[0-9][0-9]$ ]]; then
      mv -- "${temporary_body}" "${output}"
      rm -f -- "${temporary_headers}"
      return 0
    fi

    retry_reason=
    if ((curl_status != 0)) && is_transient_curl_exit "${curl_status}"; then
      retry_reason="curl exit ${curl_status}"
    elif ((curl_status == 0)) && is_transient_http_response \
      "${http_status}" "${temporary_headers}" "${temporary_body}"; then
      retry_reason="HTTP ${http_status}"
    fi

    if [[ -z ${retry_reason} ]] || ((attempt == attempts)); then
      rm -f -- "${temporary_body}" "${temporary_headers}"
      if ((curl_status != 0)); then
        die "request failed for ${url} (curl exit ${curl_status})"
      fi
      die "request failed for ${url} (HTTP ${http_status:-unknown})"
    fi

    log "temporary ${retry_reason} for ${url} (attempt ${attempt}/${attempts}); retrying in ${delay}s"
    sleep "${delay}"
    delay=$(next_retry_delay "${delay}" "${max_delay}")
  done
}

github_api_get() {
  local output=${1:?output path is required}
  local url=${2:?URL is required}
  local curl_args=(
    --header 'Accept: application/vnd.github+json'
    --header 'X-GitHub-Api-Version: 2022-11-28'
  )

  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    curl_args+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  http_get_with_retry "${output}" 300 "${url}" "${curl_args[@]}"
}

download_get() {
  local output=${1:?output path is required}
  local url=${2:?URL is required}
  http_get_with_retry "${output}" 900 "${url}"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

image_manifest_digest() {
  local image_reference=${1:?image reference is required}
  local wait_for_presence=${2:-false}
  [[ ${wait_for_presence} == true || ${wait_for_presence} == false ]] \
    || die 'wait-for-presence must be true or false'
  local attempts=${REGISTRY_RETRY_ATTEMPTS:-8}
  local delay=${REGISTRY_RETRY_INITIAL_DELAY:-3}
  local max_delay=${REGISTRY_RETRY_MAX_DELAY:-30}
  require_positive_integer REGISTRY_RETRY_ATTEMPTS "${attempts}"
  require_positive_integer REGISTRY_RETRY_INITIAL_DELAY "${delay}"
  require_positive_integer REGISTRY_RETRY_MAX_DELAY "${max_delay}"

  local temporary_dir manifest_file error_file
  temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/rulego-manifest.XXXXXX")
  manifest_file=${temporary_dir}/manifest.json
  error_file=${temporary_dir}/error.log

  local attempt status digest retry_reason
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    retry_reason=
    : >"${error_file}"
    if docker buildx imagetools inspect "${image_reference}" \
      --format '{{json .Manifest}}' >"${manifest_file}" 2>"${error_file}"; then
      if ! jq -e . "${manifest_file}" >/dev/null 2>&1; then
        retry_reason='invalid manifest JSON'
      elif ! jq -e '
        (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
        and ([.manifests[]?
          | select(.platform.os == "linux" and .platform.architecture == "amd64")]
          | length == 1)
        and ([.manifests[]?
          | select(.platform.os == "linux" and .platform.architecture == "arm64")]
          | length == 1)
      ' "${manifest_file}" >/dev/null; then
        if [[ ${wait_for_presence} == true ]]; then
          retry_reason='incomplete image index'
        else
          log "image index is absent or incomplete (requires exactly one linux/amd64 and one linux/arm64): ${image_reference}"
          rm -rf -- "${temporary_dir}"
          return 1
        fi
      else
        digest=$(jq -er '.digest' "${manifest_file}")
        rm -rf -- "${temporary_dir}"
        printf '%s\n' "${digest}"
        return 0
      fi
    else
      status=$?
      if grep -Eqi 'manifest unknown|name unknown|(^|[[:space:]:])not found([[:space:]]|$)' "${error_file}"; then
        if [[ ${wait_for_presence} == true ]]; then
          retry_reason='image manifest not yet visible'
        else
          rm -rf -- "${temporary_dir}"
          return 1
        fi
      else
        retry_reason="registry command exit ${status}"
      fi
    fi

    if ((attempt == attempts)); then
      if [[ -s ${error_file} ]]; then
        cat "${error_file}" >&2
      else
        log "${retry_reason} after ${attempts} attempts: ${image_reference}"
      fi
      rm -rf -- "${temporary_dir}"
      return 2
    fi

    log "temporary ${retry_reason} for ${image_reference} (attempt ${attempt}/${attempts}); retrying in ${delay}s"
    sleep "${delay}"
    delay=$(next_retry_delay "${delay}" "${max_delay}")
  done
}

retry_command() {
  local attempts=${1:?attempt count is required}
  local delay=${2:?initial delay is required}
  shift 2

  require_positive_integer attempts "${attempts}"
  require_positive_integer delay "${delay}"

  local attempt status
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if "$@"; then
      return 0
    else
      status=$?
    fi

    if ((attempt == attempts)); then
      return "${status}"
    fi

    log "command failed (attempt ${attempt}/${attempts}); retrying in ${delay}s"
    sleep "${delay}"
    delay=$(next_retry_delay "${delay}" 30)
  done
}
