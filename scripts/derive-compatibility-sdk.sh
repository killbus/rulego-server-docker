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
# Three modes:
#
#   derive <revision|auto>
#                        -- print the block for the SDK published by that revision. `auto` names the
#                           revision for you: it is the newest published generation other than this
#                           lock's own identity, which is also what `check` demands the block record.
#                           Either way nothing here is typed, so nothing here can be typed wrong.
#   previous             -- print the newest published generation as its identity and its commit, tab
#                           separated. It is what `check` will insist on, and an operator can read it
#                           before editing anything.
#   check [lock]         -- read the block the lock already carries, resolve the tag it names, and
#                           refuse if the published index or either architecture image is not those
#                           bytes; then refuse if that tag is not the newest published generation. This
#                           is the gate that turns a mistyped or forgotten rotation into a red pull
#                           request instead of a compatibility probe that quietly loads something else.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

usage() {
  printf 'Usage: %s derive <revision|auto>   prints the .compatibility.previous_sdk block\n' \
    "%s previous                 prints the newest published generation and its commit\n" \
    "%s check [plugin-abi.lock]  verifies the recorded block against the registry and against publication order\n" \
    "${0##*/}" "${0##*/}" "${0##*/}" >&2
  exit 2
}

# The lock this script is run against. `check` may be pointed at another file, and the ordering always
# excludes this lock's own identity, because a release cannot be its own predecessor.
current_lock=${PLUGIN_ABI_LOCK:-plugin-abi.lock}

current_sdk_repository() {
  local lock_file=${1:?plugin ABI lock is required}
  local owner image

  owner=${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}
  owner=${owner,,}
  image=$(jq -er '.release.sdk_image' "${lock_file}") ||
    die "${lock_file} records no SDK image, so there is no repository whose tags could be listed"
  printf 'ghcr.io/%s/%s\n' "${owner}" "${image}"
}

# The identity this lock is about to publish. It is never its own predecessor, so every ordering question
# is asked with it excluded -- and an answer that failed to exclude it would derive a block pointing at the
# release currently being made.
current_lock_identity() {
  local lock_file=${1:?plugin ABI lock is required} identity

  identity=$(jq -er '.abi_id' "${lock_file}") ||
    die "${lock_file} records no identity to exclude from the published order"
  printf '%s\n' "${identity}"
}

require_command git jq docker
mode=${1:-}
[[ -n ${mode} ]] || usage
shift

temporary_dir=$(mktemp -d "${TMPDIR:-${repository_root}/tmp}/derive-compatibility-sdk.XXXXXX")
trap 'rm -rf -- "${temporary_dir}"' EXIT

derive_compatibility_record() {
  local previous_rev=${1:?revision of the previous release is required}
  local previous_lock abi_id owner repository reference index_digest manifest status labelled

  # The identity comes from the lock the previous release was cut with -- never from the caller, and
  # never recomputed here. Recomputing is what breaks: the identity function's domain has already
  # changed once, so today's function hashes an older contract into a string that is not the name that
  # generation is published under. Measured against the live registry: not one of the four published
  # SDK tags other than this identity validates against today's schema, because `.abi.packaging` was
  # added after all four were cut. Requiring that validation therefore refuses every real predecessor,
  # which is exactly why this block has gone on being transcribed by hand.
  #
  # What is checked instead is three independent claims about the same bytes agreeing: the lock at that
  # revision records this identity, the published index annotates itself with this identity, and the
  # amd64 image inside that index names that revision as the commit it was built from. Any one of the
  # three is a string; all three agreeing is a provenance, and it survives a change of identity
  # function, which a recomputed hash does not.
  previous_lock=${temporary_dir}/previous.lock
  git show "${previous_rev}:plugin-abi.lock" >"${previous_lock}" ||
    die "no plugin-abi.lock in ${previous_rev}: the block cannot be derived from a contract that was never locked"
  previous_rev=$(git rev-parse "${previous_rev}^{commit}") ||
    die "${previous_rev} is not a commit of this checkout; nothing can be derived from a revision that is not here"
  abi_id=$(jq -er '.abi_id' "${previous_lock}") ||
    die "the lock at ${previous_rev:0:9} records no identity to derive from"
  [[ ${abi_id} =~ ^abi-[0-9a-f]{64}$ ]] ||
    die "the lock at ${previous_rev:0:9} records an identity that is not an ABI digest"

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
    elif ((.annotations // {})["io.rulego.abi.id"] // "unlabelled") != $abi_id
      then error("the published index annotates an identity other than the tag it answers to")
    else . end |
    {abi_id: $abi_id, repository: $repository, index_digest: $index,
     children: {amd64: child("amd64"), arm64: child("arm64")}} |
    if .children.amd64 == .children.arm64
    then error("both architectures resolve to the same digest, which is a mislabelled index")
    else . end
  ' "${manifest}"

  # The third claim: the bytes themselves say which commit produced them. A tag that resolves, annotates
  # itself correctly and holds two architectures could still be the output of a different revision than
  # the one asked for -- and then the block would name a predecessor that release never was.
  labelled=$(cast_config_label "${repository}" "${index_digest}" org.opencontainers.image.revision) ||
    die "cannot read the packaging revision out of the published image at ${reference}; nothing was derived"
  [[ ${labelled} == "${previous_rev}" ]] ||
    die "the published image at ${abi_id:0:12} was built from ${labelled:0:9}, not from ${previous_rev:0:9}"
}

# Every published generation of the SDK other than the identity being released, dated by the commit each
# published image names in its own config. A generation that cannot be dated is refused rather than
# skipped: dropping the one entry that would have won the ordering is exactly how a stale record ends up
# looking current, and this script cannot tell "no such generation" from "I could not read it" any other
# way.
published_sdk_generations() {
  local repository=${1:?repository is required} self=${2:?this identity is required}
  local tags tag index status revision date

  # The list is materialised before it is walked, and a failure to obtain it stops the script there.
  # Reading it inside the loop's own subshell would let `die` end only that subshell: the loop would then
  # finish with a short list, and a generation that could not be read would look exactly like a generation
  # that was never published -- which is how the newest published release stops existing for the order.
  #
  # The guard has to be written out because this function is always called through a command substitution,
  # and a command substitution does not inherit errexit by default: without the explicit exit, the pages
  # that did arrive would be handed back as the whole repository and the order would name the newest
  # generation it happened to see.
  tags=$(registry_tags "${repository}") || exit 1
  while IFS= read -r tag; do
    [[ ${tag} =~ ^abi-[0-9a-f]{64}$ ]] || continue
    [[ ${tag} == "${self}" ]] && continue
    if index=$(image_reference_digest "${repository}:${tag}"); then
      :
    else
      status=$?
      ((status != 1)) ||
        die "${tag:0:12} was listed by the registry and does not resolve: the list and the tag disagree, so nothing here can be ordered"
      die "${tag:0:12} was listed by the registry and would not answer; a generation is not dropped from an order because reading it failed"
    fi
    if ! revision=$(cast_config_label "${repository}" "${index}" org.opencontainers.image.revision); then
      die "${tag:0:12}: the published image could not be read; no answer is not the same as no generation"
    fi
    [[ ${revision} =~ ^[0-9a-f]{40}$ ]] ||
      die "${tag:0:12} does not name the commit it was built from, so it cannot be placed in an order"
    git cat-file -e "${revision}^{commit}" 2>/dev/null ||
      die "${tag:0:12}: the commit its own image names (${revision:0:9}) is not in this checkout, so this generation cannot be dated"
    date=$(git log -n 1 --format=%ct "${revision}") ||
      die "${tag:0:12}: its own commit could not be dated, so no order can be answered"
    printf '%s\t%s\t%s\n' "${date}" "${revision}" "${tag}"
  done < <(printf '%s\n' "${tags}" | LC_ALL=C sort)
}

# The newest of them. Two orders have to agree for that to mean anything: the commit dates, and the
# ancestry of the commits themselves. A publication made from an older commit after a newer one -- which
# a dispatch on any ref makes possible -- would otherwise be answered with whichever clock this script
# happened to read first.
newest_published_sdk_generation() {
  local repository=${1:?repository is required} self=${2:?this identity is required}
  local generations chosen chosen_date chosen_rev chosen_tag tied line_date line_rev line_tag

  generations=$(published_sdk_generations "${repository}" "${self}") ||
    die "${repository}: the published SDK generations could not be listed, so no newest generation is named"
  [[ -n ${generations} ]] ||
    die "no published SDK generation other than ${self:0:12}: there is nothing for a compatibility record to point at"
  chosen=$(printf '%s\n' "${generations}" | sort -t$'\t' -k1,1nr -k3,3 | head -n 1)
  IFS=$'\t' read -r chosen_date chosen_rev chosen_tag <<<"${chosen}"

  tied=$(awk -F'\t' -v want="${chosen_date}" '$1 == want' <<<"${generations}" | awk 'END { print NR }')
  (( tied == 1 )) ||
    die "two published generations carry the same commit date (${chosen_date}), so history cannot say which one this release follows"

  while IFS=$'\t' read -r line_date line_rev line_tag; do
    # The row that won is not its own descendant, and the tie above means every other row is strictly older
    # by date -- so the rows left are exactly the ones whose history contradicts the winner.
    [[ ${line_date} == "${chosen_date}" ]] && continue
    if git merge-base --is-ancestor "${chosen_rev}" "${line_rev}"; then
      die "${chosen_tag:0:12} is newest by date but ${line_tag:0:12} was built from a commit descending from it: publication order and history disagree, and nothing here may guess which one to be compatible with"
    fi
  done <<<"${generations}"

  printf '%s\t%s\n' "${chosen_tag}" "${chosen_rev}"
}

# The freshness half of `check`. A forgotten rotation is not visible in the recorded bytes: the tag it
# names is published, the digests match, and every check that exists today is satisfied -- the record is
# simply one generation behind, and the compatibility probe then proves less than it claims to.
assert_record_is_newest() {
  local lock_file=${1:?plugin ABI lock is required}
  local record repository recorded_abi self newest newest_tag newest_rev

  record=$(jq -ec '.compatibility.previous_sdk' "${lock_file}") ||
    die "the lock records no compatibility SDK: ${lock_file}"
  repository=$(jq -er '.repository' <<<"${record}")
  recorded_abi=$(jq -er '.abi_id' <<<"${record}")
  self=$(jq -er '.abi_id' "${lock_file}")

  newest=$(newest_published_sdk_generation "${repository}" "${self}") ||
    die "${repository}: the published generations are not legible, so the recorded compatibility SDK was not verified"
  IFS=$'\t' read -r newest_tag newest_rev <<<"${newest}"
  [[ ${newest_tag} == "${recorded_abi}" ]] ||
    die "the recorded compatibility SDK ${recorded_abi:0:12} is not the newest published generation: ${newest_tag:0:12}, built from $(git rev-parse --short "${newest_rev}"), is. Rotate with '${0##*/} derive auto'."
  log "compatibility record is the newest published generation: ${newest_tag:0:12}"
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
  derive)
    (( $# == 1 )) || usage
    revision=$1
    if [[ ${revision} == auto ]]; then
      # `auto` is the point of the mode: the revision of the previous release is a fact about the
      # registry, not something anyone should have to remember. It is the same value `check` will insist
      # on, so deriving from it cannot produce a block that the gate then refuses.
      # The guard is written out because a command substitution does not inherit errexit: unguarded, a
      # registry that would not be listed would leave `revision` empty and `derive` would answer with a
      # refusal about a missing lock instead of the listing that actually failed.
      newest=$(newest_published_sdk_generation \
        "$(current_sdk_repository "${current_lock}")" "$(current_lock_identity "${current_lock}")") ||
        die 'auto could not name the newest published generation; nothing was derived'
      revision=${newest#*$'\t'}
    fi
    derive_compatibility_record "${revision}"
    ;;
  previous)
    (( $# == 0 )) || usage
    newest=$(newest_published_sdk_generation \
      "$(current_sdk_repository "${current_lock}")" "$(current_lock_identity "${current_lock}")") ||
      die 'the newest published generation could not be named; nothing was printed as an answer'
    printf '%s\n' "${newest}"
    ;;
  check)
    (( $# <= 1 )) || usage
    lock=${1:-${current_lock}}
    check_compatibility_record "${lock}"
    assert_record_is_newest "${lock}"
    ;;
  *) usage ;;
esac
