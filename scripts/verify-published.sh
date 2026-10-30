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

image_repository=${image_reference%%@*}
if [[ ${image_repository##*/} == *:* ]]; then
  image_repository=${image_repository%:*}
fi

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

if verified_digest=$(image_manifest_digest "${image_reference}" true); then
  :
else
  status=$?
  if ((status == 1)); then
    die "published image is missing a complete linux/amd64 and linux/arm64 index: ${image_reference}"
  fi
  die "could not inspect published image after bounded retries: ${image_reference}"
fi

index_manifest=${verification_dir}/index.json
retry_command 5 3 docker buildx imagetools inspect "${image_reference}" \
  --format '{{json .Manifest}}' >"${index_manifest}"
# Every native image pushed with provenance and SBOM contributes one attestation
# manifest, so the assembled index must pair both platforms with attestation.
jq -e '
  (.manifests | map(select(.platform.os == "linux"))) as $images |
  (.manifests | map(select(.platform.os == "unknown" and .platform.architecture == "unknown"
    and .annotations["vnd.docker.reference.type"] == "attestation-manifest"))) as $attestations |
  (.manifests | length) == ($images | length + ($attestations | length)) and
  ([$images[] | select(.platform.architecture == "amd64")] | length == 1) and
  ([$images[] | select(.platform.architecture == "arm64")] | length == 1) and
  ($attestations | length >= 2) and
  ($images | all(.digest as $digest
    | $attestations | any(.annotations["vnd.docker.reference.digest"] == $digest))) and
  ($attestations | all(.annotations["vnd.docker.reference.digest"] as $digest
    | $images | any(.digest == $digest)))
' "${index_manifest}" >/dev/null \
  || die "published image index is missing its attestation manifests: ${image_reference}"

verify_attestation_predicates() {
  local architecture=$1
  local image_digest predicates attestation
  image_digest=$(jq -er --arg arch "${architecture}" '
    .manifests[]
    | select(.platform.os == "linux" and .platform.architecture == $arch)
    | .digest
  ' "${index_manifest}")

  predicates=
  while IFS= read -r attestation; do
    [[ -n ${attestation} ]] || continue
    predicates+=$(retry_command 5 3 docker buildx imagetools inspect \
      "${image_repository}@${attestation}" --raw \
      | jq -r '[.layers[]?.annotations["in-toto.io/predicate-type"]] | .[]')
    predicates+=$'\n'
  done < <(jq -r --arg digest "${image_digest}" '
    .manifests[]
    | select(.platform.os == "unknown"
      and .annotations["vnd.docker.reference.type"] == "attestation-manifest"
      and .annotations["vnd.docker.reference.digest"] == $digest)
    | .digest
  ' "${index_manifest}")

  grep -q 'slsa.dev/provenance' <<<"${predicates}" \
    || die "published image has no SLSA provenance attestation for ${architecture}: ${image_reference}"
  grep -q 'spdx.dev/Document' <<<"${predicates}" \
    || die "published image has no SBOM attestation for ${architecture}: ${image_reference}"
  log "Verified SLSA provenance and SBOM attestations for ${architecture} of ${image_reference}"
}

verify_attestation_predicates amd64
verify_attestation_predicates arm64

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

# Written last, on purpose. This line is what authorises scripts/promote-alias.sh to move a public
# name, so emitting it before the attestations or the executables had been checked would hand a
# licence to a run that was about to fail. A verification that dies partway therefore leaves no
# output at all, and the promotion step receives an empty digest it cannot act on.
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  printf 'verified_digest=%s\n' "${verified_digest}" >>"${GITHUB_OUTPUT}"
fi

log "Verified published multi-platform image: ${image_reference}"
