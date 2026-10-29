#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

if (($# != 2)); then
  printf 'Usage: %s <digest-directory> <image-reference>\n' "${0##*/}" >&2
  exit 2
fi

digest_dir=$1
image_reference=$2
require_command docker

[[ -d ${digest_dir} ]] || die "digest directory is missing: ${digest_dir}"

# Each architecture job records "<architecture>.<hex digest>", so the assembled
# index can be required to cover both platforms with distinct images instead of
# accepting any two hexadecimal names.
declare -A digests_by_architecture=()
shopt -s nullglob
for entry in "${digest_dir}"/*; do
  [[ -f ${entry} ]] || die "digest entry is not a regular file: ${entry}"
  name=${entry##*/}
  [[ ${name} =~ ^(amd64|arm64)\.([0-9a-f]{64})$ ]] \
    || die "unexpected digest file name: ${name} (expected <amd64|arm64>.<64 hex characters>)"
  architecture=${BASH_REMATCH[1]}
  digest=${BASH_REMATCH[2]}
  [[ -z ${digests_by_architecture[$architecture]:-} ]] \
    || die "duplicate digest entry for ${architecture}"
  digests_by_architecture[$architecture]=$digest
done
shopt -u nullglob

for architecture in amd64 arm64; do
  [[ -n ${digests_by_architecture[$architecture]:-} ]] \
    || die "no image digest was published for ${architecture}"
done
[[ ${digests_by_architecture[amd64]} != "${digests_by_architecture[arm64]}" ]] \
  || die "linux/amd64 and linux/arm64 resolve to the same image digest"

tags=()
while IFS= read -r tag; do
  [[ -z ${tag} ]] || tags+=("${tag}")
done <<<"${TAGS-}"
((${#tags[@]} > 0)) || die 'no image tags were supplied'

# The metadata inputs list the immutable tag for this run first, so the first tag
# is the one reference the caller should verify.
first_tag=${tags[0]}
[[ ${first_tag} == "${image_reference}:"* ]] \
  || die "first image tag does not belong to ${image_reference}: ${first_tag}"

args=()
for tag in "${tags[@]}"; do
  args+=(--tag "${tag}")
done
while IFS= read -r annotation; do
  # docker/metadata-action already prefixes each annotation with its level.
  [[ -z ${annotation} ]] || args+=(--annotation "${annotation}")
done <<<"${ANNOTATIONS-}"

sources=()
for architecture in amd64 arm64; do
  sources+=("${image_reference}@sha256:${digests_by_architecture[$architecture]}")
done

retry_command 4 2 docker buildx imagetools create "${args[@]}" "${sources[@]}"

log "Published multi-platform index ${first_tag}"
# The assembled index carries each platform's child image manifest rather than
# the per-architecture index digest reported here, so its completeness and
# attestation pairing is verified through the tag by scripts/verify-published.sh.
# The caller verifies the reference this run actually published instead of
# re-deriving it from the metadata inputs.
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  printf 'canonical_tag=%s\n' "${first_tag}" >>"${GITHUB_OUTPUT}"
fi
