#!/usr/bin/env bash
#
# Derive the `.compatibility.previous_sdk` block from the registry, and check a recorded one against
# it, instead of transcribing either.
#
# The compatibility probe loads a plugin built against the previous SDK into the new runtime, so this
# block has to name the bytes that are actually published. Two of its four values are digests nothing
# computes: they were copied by hand out of a release record, and a wrong digit changes which image
# the probe loads while every offline check stays green, because no offline check can see a registry.
#
# Two modes:
#
#   derive <revision>  -- point it at any revision whose plugin-abi.lock was the released contract. It
#                         reads that contract's identity from git, resolves the published tag, and
#                         prints the block. Nothing here is typed, so nothing here can be typed wrong.
#   check [lock]       -- read the block the lock already carries, resolve the tag it names, and
#                         refuse if the published index or either architecture image is not those
#                         bytes. This is the gate that turns a mistyped rotation into a red pull
#                         request instead of a compatibility probe that quietly loads something else.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

usage() {
  printf 'Usage: %s derive <revision-of-the-previous-release>   prints the .compatibility.previous_sdk block\n' \
    "%s check [plugin-abi.lock]                            verifies the recorded block against the registry\n" \
    "${0##*/}" "${0##*/}" >&2
  exit 2
}

require_command git jq docker
mode=${1:-}
[[ -n ${mode} ]] || usage
shift

temporary_dir=$(mktemp -d "${TMPDIR:-${repository_root}/tmp}/derive-compatibility-sdk.XXXXXX")
trap 'rm -rf -- "${temporary_dir}"' EXIT

derive_compatibility_record() {
  local previous_rev=${1:?revision of the previous release is required}
  local previous_lock abi_id owner repository reference index_digest manifest status

  # The identity comes from the lock, never from the caller. A revision whose lock is not a legal
  # contract cannot have been released, so reading an identity off it would describe a product that
  # nothing built, and the probe would then test a compatibility claim nobody made.
  previous_lock=${temporary_dir}/previous.lock
  git show "${previous_rev}:plugin-abi.lock" >"${previous_lock}" ||
    die "no plugin-abi.lock in ${previous_rev}: the block cannot be derived from a contract that was never locked"
  PLUGIN_ABI_LOCK=${previous_lock} "${repository_root}/scripts/plugin-abi.sh" validate --candidate ||
    die "the lock at ${previous_rev} is not a valid Plugin ABI contract"
  abi_id=$(jq -er '.abi_id' "${previous_lock}")

  # The repository is the one that contract would have published to, derived the way publication derives
  # it: the lock's image name and the workflow's owner. A block written for a namespace nothing writes
  # tags to would send the compatibility probe to an image that never existed.
  owner=${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}
  owner=${owner,,}
  repository=ghcr.io/${owner}/$(jq -er '.release.sdk_image' "${previous_lock}")
  reference=${repository}:${abi_id}

  # A name that does not resolve is not a previous release. An absent tag and a registry that would not
  # answer are reported apart, because one means the revision is wrong and the other means retry.
  index_digest=''
  if index_digest=$(image_reference_digest "${reference}"); then
    :
  else
    status=$?
    ((status != 1)) || die "no published SDK tag to derive: ${reference}"
    die "the registry could not answer for ${reference}; nothing was derived"
  fi

  manifest=${temporary_dir}/index.json
  docker buildx imagetools inspect "${reference}" --format '{{json .Manifest}}' >"${manifest}" ||
    die "cannot read the published index at ${reference}; nothing was derived"

  # Both architectures must be present, exactly once each, and must differ: an index that resolves both
  # platforms to one digest is mislabelled, and the probe would silently compare one image with itself.
  jq -e --arg abi_id "${abi_id}" --arg repository "${repository}" --arg index "${index_digest}" '
    def child($arch):
      [.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest] |
      if length == 1 then .[0] else error("the published index does not hold exactly one linux/" + $arch) end;
    if (.digest // $index) != $index then error("the published index manifest is not the digest the tag resolves to")
    else . end |
    {abi_id: $abi_id, repository: $repository, index_digest: $index,
     children: {amd64: child("amd64"), arm64: child("arm64")}} |
    if .children.amd64 == .children.arm64
    then error("both architectures resolve to the same digest, which is a mislabelled index")
    else . end
  ' "${manifest}"
}

# The other half: the record already in the lock is checked against the registry, so a transcribed
# digit that validates offline stops being invisible. Publication reads those two digests when it
# pulls the previous SDK into the compatibility probe, which is the first moment a wrong value would
# otherwise surface -- after the images for a release have already been written.
check_compatibility_record() {
  local lock_file=${1:?plugin ABI lock is required}
  local record repository abi_id recorded_index amd64 arm64 reference index_digest manifest status

  record=$(jq -ec '.compatibility.previous_sdk' "${lock_file}") ||
    die "the lock records no compatibility SDK: ${lock_file}"
  repository=$(jq -er '.repository' <<<"${record}")
  abi_id=$(jq -er '.abi_id' <<<"${record}")
  recorded_index=$(jq -er '.index_digest' <<<"${record}")
  amd64=$(jq -er '.children.amd64' <<<"${record}")
  arm64=$(jq -er '.children.arm64' <<<"${record}")
  reference=${repository}:${abi_id}

  # Absent and unanswered are reported apart, as in derive mode: one means the record names a
  # release that never happened, the other means the check could not be made at all.
  if index_digest=$(image_reference_digest "${reference}"); then
    :
  else
    status=$?
    ((status != 1)) || die "the recorded compatibility SDK tag is not published: ${reference}"
    die "the registry could not answer for ${reference}; the record was not checked"
  fi

  manifest=${temporary_dir}/check-index.json
  docker buildx imagetools inspect "${reference}" --format '{{json .Manifest}}' >"${manifest}" ||
    die "cannot read the published index at ${reference}; the record was not checked"

  jq -e --arg resolved "${index_digest}" --arg recorded "${recorded_index}" \
    --arg amd64 "${amd64}" --arg arm64 "${arm64}" '
    def child($arch):
      [.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest] |
      if length == 1 then .[0] else error("the published index does not hold exactly one linux/" + $arch) end;
    if (.digest // $resolved) != $resolved then error("the published index manifest is not the digest the tag resolves to")
    elif $resolved != $recorded then error("the tag resolves to different bytes than the record names")
    elif child("amd64") != $amd64 then error("the record does not name the published linux/amd64 image")
    elif child("arm64") != $arm64 then error("the record does not name the published linux/arm64 image")
    else . end
  ' "${manifest}" >/dev/null || die "the compatibility record does not match the registry: ${reference}"

  log "compatibility record matches the registry: ${reference}"
}


case ${mode} in
  derive) (( $# == 1 )) || usage; derive_compatibility_record "$1" ;;
  check)  (( $# <= 1 )) || usage; check_compatibility_record "${1:-plugin-abi.lock}" ;;
  *) usage ;;
esac
