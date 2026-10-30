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

# MOVING_ALIASES declares, as space-separated tag names, which of those tags are allowed to be
# re-pointed later. Nothing here infers movability from tag order or from a `latest` prefix: order was
# the defect. The metadata inputs happen to list the immutable tag first today, so a single write
# carried both the version tag and `latest`, and the public name pointed at content no one had
# verified yet.
declared=${MOVING_ALIASES-}
# Newlines are folded into the separator rather than left to `read`, which stops at the first line:
# a caller that passes one alias per line would otherwise have every alias after the first dropped,
# and the alias it dropped would be published as if it were immutable. The exactly-one-canonical
# guard below does turn that accident red today, but a parser that is total does not depend on a
# guard happening to cover it.
read -r -a aliases <<<"${declared//[$'\n\r']/ }"
alias_refs=()
# A bash array expands to one empty element under "${arr[@]-}" when it is empty, so the names are
# filtered rather than trusted: an unset MOVING_ALIASES used to manufacture a `${image_reference}:`
# alias out of nothing, and the run then failed for a reason that had nothing to do with its tags.
for name in "${aliases[@]-}"; do
  [[ -n ${name} ]] || continue
  alias_refs+=("${image_reference}:${name}")
done

canonical_tags=()
for tag in "${tags[@]}"; do
  [[ ${tag} == "${image_reference}:"* ]] \
    || die "image tag does not belong to ${image_reference}: ${tag}"
  if [[ -n ${alias_refs[*]-} ]] && printf '%s\n' "${alias_refs[@]}" | grep -Fxq -- "${tag}"; then
    continue
  fi
  canonical_tags+=("${tag}")
done

if ((${#alias_refs[@]} > 0)); then
  for ref in "${alias_refs[@]}"; do
    printf '%s\n' "${tags[@]}" | grep -Fxq -- "${ref}" \
      || die "moving alias was not produced by the metadata action: ${ref}"
  done
fi

# Exactly one immutable tag per run: the version tag, or the staging tag while a release is measured.
# Two canonical tags means something movable was left undeclared, which is precisely how the alias
# came to be published before verification; zero means every tag was declared movable. Either way
# this is a red rather than a guess, and the caller could not say which name it verified.
((${#canonical_tags[@]} == 1)) \
  || die "expected exactly one canonical tag, found ${#canonical_tags[@]}: ${canonical_tags[*]-}"
canonical_tag=${canonical_tags[0]}

args=(--tag "${canonical_tag}")
while IFS= read -r annotation; do
  # docker/metadata-action already prefixes each annotation with its level.
  [[ -z ${annotation} ]] || args+=(--annotation "${annotation}")
done <<<"${ANNOTATIONS-}"

sources=()
for architecture in amd64 arm64; do
  sources+=("${image_reference}@sha256:${digests_by_architecture[$architecture]}")
done

retry_command 4 2 docker buildx imagetools create "${args[@]}" "${sources[@]}"

log "Published multi-platform index ${canonical_tag}"
# The assembled index carries each platform's child image manifest rather than
# the per-architecture index digest reported here, so its completeness and
# attestation pairing is verified through the tag by scripts/verify-published.sh.
# The caller verifies the reference this run actually published instead of
# re-deriving it from the metadata inputs.
# Declared aliases are withheld here so that unverified content is reachable only under its immutable
# name. scripts/promote-alias.sh points them at the digest the verifier reports, which is the gap this
# pipeline did not have: the write and the check that authorises it used to be one command. There is
# deliberately no readback of the digest here; the number that matters is the one taken after the
# attestations and executables were checked, not the one taken immediately after the push.
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    printf 'canonical_tag=%s\n' "${canonical_tag}"
    printf 'moving_aliases=%s\n' "${alias_refs[*]-}"
  } >>"${GITHUB_OUTPUT}"
fi
