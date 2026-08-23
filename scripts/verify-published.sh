#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

if (($# != 1)); then
  printf 'Usage: %s <registry/image:tag>\n' "${0##*/}" >&2
  exit 2
fi

image_reference=$1
require_command docker jq sha256sum

build_dir=${repository_root}/build
[[ -f ${build_dir}/version ]] || die 'build/version is missing; run fetch-release.sh first'

verification_dir=$(mktemp -d "${TMPDIR:-/tmp}/rulego-verify-published.XXXXXX")
container_id=
cleanup() {
  if [[ -n ${container_id} ]]; then
    docker rm --force "${container_id}" >/dev/null 2>&1 || true
  fi
  rm -rf -- "${verification_dir}"
}
trap cleanup EXIT

if image_manifest_digest "${image_reference}" true >/dev/null; then
  :
else
  status=$?
  if ((status == 1)); then
    die "published image is missing a complete linux/amd64 and linux/arm64 index: ${image_reference}"
  fi
  die "could not inspect published image after bounded retries: ${image_reference}"
fi

for architecture in amd64 arm64; do
  expected_file=${build_dir}/${architecture}/rulego-server.sha256
  [[ -f ${expected_file} ]] || die "missing expected executable checksum: ${expected_file}"
  expected_sha=$(<"${expected_file}")
  [[ ${expected_sha} =~ ^[0-9a-f]{64}$ ]] \
    || die "invalid expected executable checksum for ${architecture}"

  retry_command 5 3 docker pull --platform "linux/${architecture}" "${image_reference}" >/dev/null
  # Keep the platform selector on create. Inspecting a multi-platform tag as a
  # local image can otherwise resolve its host-architecture child even after a
  # foreign-platform pull.
  container_id=$(docker create --platform "linux/${architecture}" "${image_reference}")
  extracted_binary=${verification_dir}/rulego-server-${architecture}
  docker cp "${container_id}:/app/rulego-server" "${extracted_binary}"
  docker rm "${container_id}" >/dev/null
  container_id=

  actual_sha=$(sha256_file "${extracted_binary}")
  [[ ${actual_sha} == "${expected_sha}" ]] \
    || die "published image checksum mismatch for ${architecture}: expected ${expected_sha}, got ${actual_sha}"
  log "Verified published image executable SHA-256 for ${architecture}: ${actual_sha}"
done

log "Verified published multi-platform image: ${image_reference}"
