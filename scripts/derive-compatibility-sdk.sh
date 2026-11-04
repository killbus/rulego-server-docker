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
#   derive <revision|abi-id|auto>
#                        -- print the block for one published SDK generation. A revision asks "the release
#                           cut from this source"; an identity asks "the release published under this name",
#                           which is the only question answerable about a generation whose commit is no
#                           longer reachable here. `auto` names the generation for you: it is the newest
#                           published one other than this lock's own identity, which is also what `check`
#                           demands the block record. It answers with the identity, never with a commit,
#                           because a commit is the one thing a published generation may no longer have.
#                           Either way nothing here is typed, so nothing here can be typed wrong.
#   previous             -- print the newest published generation as its identity and its commit, tab
#                           separated. The commit is `-` when this checkout cannot read it, which is a
#                           fact about history here, not about the release. It is what `check` will insist
#                           on, and an operator can read it before editing anything.
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
  printf 'Usage: %s derive <revision|abi-id|auto>  prints the .compatibility.previous_sdk block\n' \
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
  local source=${1:?a published identity or a revision is required}
  local previous_lock abi_id repository reference index_digest manifest status labelled recorded asked_rev=''

  # Two ways of naming the same generation, because two different things are being asked.
  #
  # A revision asks "the release cut from this source". Its identity is read out of the lock that revision
  # carries, never recomputed: the identity function's domain changed once, so today's function hashes an older
  # contract into a name that generation was never published under. Measured against the live registry, none of
  # the four published SDK tags other than this identity validates under today's schema -- `.abi.packaging` was
  # added after all four were cut -- which is exactly why demanding that validation left transcription as the
  # only answer that could ever ship.
  #
  # An identity asks "the release published under this name". That is the only question answerable about a
  # generation whose commit is no longer reachable here, and the identity then comes from the published index's
  # own annotation instead of a lock: the content says what it is, and the name has to agree with it.
  if [[ ${source} =~ ^abi-[0-9a-f]{64}$ ]]; then
    abi_id=${source}
    repository=$(current_sdk_repository "${current_lock}")
  else
    previous_lock=${temporary_dir}/previous.lock
    git show "${source}:plugin-abi.lock" >"${previous_lock}" ||
      die "no plugin-abi.lock in ${source}: the block cannot be derived from a contract that was never locked"
    asked_rev=$(git rev-parse "${source}^{commit}") ||
      die "${source} is not a commit of this checkout; nothing can be derived from a revision that is not here"
    abi_id=$(jq -er '.abi_id' "${previous_lock}") ||
      die "the lock at ${asked_rev:0:9} records no identity to derive from"
    [[ ${abi_id} =~ ^abi-[0-9a-f]{64}$ ]] ||
      die "the lock at ${asked_rev:0:9} records an identity that is not an ABI digest"
    repository=$(current_sdk_repository "${previous_lock}")
  fi
  reference=${repository}:${abi_id}

  # A name that does not resolve is not a previous release. An absent tag and a registry that would not answer
  # are reported apart, because one means the release never happened and the other means retry.
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

  # The index must answer to the digest the tag resolves to, annotate the identity it is named for, and hold
  # both architectures exactly once each and apart: an index that resolves both platforms to one digest is
  # mislabelled, and the probe would silently compare one image with itself.
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

  # The third claim -- what the bytes themselves say produced them -- is asserted where it can be. Against a
  # revision the image has to name that revision. Against an identity the claim is asked only if the commit it
  # names is here; if it is not, the claim is reported as unavailable rather than as true, because the other
  # two claims (the name and the content) are already settled by the registry itself.
  labelled=$(cast_config_label "${repository}" "${index_digest}" org.opencontainers.image.revision) ||
    die "cannot read the packaging revision out of the published image at ${reference}; nothing was derived"
  if [[ -n ${asked_rev} ]]; then
    [[ ${labelled} == "${asked_rev}" ]] ||
      die "the published image at ${abi_id:0:12} was built from ${labelled:0:9}, not from ${asked_rev:0:9}"
  elif [[ ${labelled} =~ ^[0-9a-f]{40}$ ]] && git cat-file -e "${labelled}^{commit}" 2>/dev/null; then
    # The commit is here, so it can be asked, and an answer that contradicts the name is a refusal rather than
    # a shrug: a generation whose own commit records no identity, or a different one, is a name that no longer
    # matches its history, and a record built from it would carry that mismatch into a release.
    recorded=$(git show "${labelled}:plugin-abi.lock" 2>/dev/null | jq -r '.abi_id // empty') || recorded=''
    [[ -n ${recorded} ]] ||
      die "the published image at ${abi_id:0:12} cites ${labelled:0:9}, which is in this checkout and carries no plugin ABI identity"
    [[ ${recorded} == "${abi_id}" ]] ||
      die "the published image at ${abi_id:0:12} cites ${labelled:0:9}, whose lock records ${recorded:0:12} instead"
    log "${abi_id:0:12} agrees with the lock at ${labelled:0:9}"
  else
    log "${abi_id:0:12} cites a revision this checkout cannot read; its identity came from the published annotation and its digests from the registry"
  fi
}

# The published generations of the SDK other than the identity being released, in the order the registry
# returns them -- which is the order they were pushed. Two clocks are read here and they are not the same
# question. Publication order answers "which release came last", and it is always readable. The commit each
# published image names in its own config answers "what was that release built from", and it is readable only
# while that commit is still reachable from this checkout.
#
# Measured on the live registry: of the five published canonical SDK tags, one cites a commit that no remote
# ref of this repository contains -- cut from a dispatch ref that was later rewritten. An order that demanded
# the second clock of every entry would therefore be unsatisfiable in CI forever: a gate that fails closed and
# never opens again is not a gate. So an entry whose commit cannot be resolved here is recorded as undated, and
# what is refused is a contradiction between the two clocks, not a missing clock.
#
# Rows are `<push position>\t<identity>\t<commit or ->\t<date or ->`, in publication order.
published_sdk_generations() {
  local repository=${1:?repository is required} self=${2:?this identity is required}
  local tags tag index status revision date annotated position=0

  # The list is materialised before it is walked, because this function is always called through a command
  # substitution and a command substitution does not inherit errexit: without the explicit exit, the pages that
  # did arrive would be handed back as the whole repository, and the order would name the newest generation it
  # happened to see.
  tags=$(registry_tags "${repository}") || exit 1
  while IFS= read -r tag; do
    [[ ${tag} =~ ^abi-[0-9a-f]{64}$ ]] || continue
    [[ ${tag} == "${self}" ]] && continue
    position=$((position + 1))

    if index=$(image_reference_digest "${repository}:${tag}"); then
      :
    else
      status=$?
      ((status != 1)) ||
        die "${tag:0:12} was listed by the registry and does not resolve: the list and the tag disagree, so nothing here can be ordered"
      die "${tag:0:12} was listed by the registry and would not answer; a generation is not dropped from an order because reading it failed"
    fi

    # The identity is read from what the published index says it is, not from the name it was pushed under, and
    # the two have to agree. A name repointed at other bytes is not an older release; it is a lie about one, and
    # ordering by it would put a release at a position its content never earned.
    annotated=$(index_annotation "${repository}:${tag}" io.rulego.abi.id) ||
      die "${tag:0:12}: the published index could not be read; no answer is not the same as no generation"
    [[ ${annotated} == "${tag}" ]] ||
      die "${tag:0:12} answers to an index that annotates ${annotated:0:12}: the name and the content of a published generation disagree"

    if ! revision=$(cast_config_label "${repository}" "${index}" org.opencontainers.image.revision); then
      die "${tag:0:12}: the published image could not be read; no answer is not the same as no generation"
    fi

    date=-
    if [[ ${revision} =~ ^[0-9a-f]{40}$ ]] && git cat-file -e "${revision}^{commit}" 2>/dev/null; then
      date=$(git log -n 1 --format=%ct "${revision}") ||
        die "${tag:0:12}: its own commit could not be read, so the two clocks cannot be compared"
    else
      revision=-
    fi
    printf '%s\t%s\t%s\t%s\n' "${position}" "${tag}" "${revision}" "${date}"
  done <<<"${tags}"
}

# The newest published generation: the last one the registry lists, cross-checked against every entry whose
# commit is reachable here. Publication order is the authority; history is the witness, and a witness that
# contradicts the authority stops the answer rather than replacing it.
newest_published_sdk_generation() {
  local repository=${1:?repository is required} self=${2:?this identity is required}
  local generations total dated position abi revision date
  local prev_date=- prev_abi='' prev_revision=''
  local last_abi last_revision

  generations=$(published_sdk_generations "${repository}" "${self}") ||
    die "${repository}: the published SDK generations could not be listed, so no newest generation is named"
  [[ -n ${generations} ]] ||
    die "no published SDK generation other than ${self:0:12}: there is nothing for a compatibility record to point at"

  total=$(awk 'END { print NR }' <<<"${generations}")
  dated=$(awk -F'\t' '$4 != "-"' <<<"${generations}" | awk 'END { print NR }')

  # The cross-check is only a check when something can be compared. A checkout that dates none of them -- a
  # shallow clone answers that way for every generation, which is how PR #21's job went red for a reason the
  # test could not see -- must refuse instead of accepting publication order with no witness at all.
  (( total == 1 || dated >= 1 )) ||
    die "${repository}: this checkout cannot date any of the ${total} published generations, so publication order has no witness to be checked against"

  while IFS=$'\t' read -r position abi revision date; do
    [[ ${date} == '-' ]] && continue
    if [[ ${prev_date} != '-' ]]; then
      (( date >= prev_date )) ||
        die "${abi:0:12} was published after ${prev_abi:0:12} and its commit is older: publication order and history disagree, and nothing here may guess which one a release has to be compatible with"
      if git merge-base --is-ancestor "${revision}" "${prev_revision}"; then
        die "${abi:0:12} was published after ${prev_abi:0:12} and is built from a commit that the earlier generation descends from: publication runs backwards against history"
      fi
    fi
    prev_date=${date}
    prev_abi=${abi}
    prev_revision=${revision}
  done <<<"${generations}"

  IFS=$'\t' read -r _ last_abi last_revision _ < <(tail -n 1 <<<"${generations}")
  log "${repository}: newest published generation is ${last_abi:0:12}, ordered by publication and cross-checked against ${dated} of ${total} generation(s)"
  printf '%s\t%s\n' "${last_abi}" "${last_revision}"
}

# The freshness half of `check`. A forgotten rotation is not visible in the recorded bytes: the tag it names is
# published, the digests match, and every check that existed before this gate is satisfied -- the record is
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
    die "the recorded compatibility SDK ${recorded_abi:0:12} is not the newest published generation: ${newest_tag:0:12}, built from $(
      [[ ${newest_rev} == '-' ]] && printf 'a revision this checkout cannot see' || git rev-parse --short "${newest_rev}"
    ), is. Rotate with '${0##*/} derive auto'."
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
    requested=$1
    if [[ ${requested} == auto ]]; then
      # `auto` is the point of the mode: which release this one follows is a fact about the registry, not
      # something anyone should have to remember. It is the same generation `check` will insist on, so
      # deriving from it cannot produce a block that the gate then refuses.
      # The identity is passed and not the commit, because the commit is the half of that answer a
      # published generation is allowed to stop having: a release cut from a dispatch ref that was later
      # rewritten cites a commit no remote ref carries, and it stays the newest published generation.
      # The guard is written out because a command substitution does not inherit errexit: unguarded, a
      # registry that would not be listed would leave `requested` empty and `derive` would answer with a
      # refusal about a missing lock instead of the listing that actually failed.
      newest=$(newest_published_sdk_generation \
        "$(current_sdk_repository "${current_lock}")" "$(current_lock_identity "${current_lock}")") ||
        die 'auto could not name the newest published generation; nothing was derived'
      requested=${newest%%$'\t'*}
    fi
    derive_compatibility_record "${requested}"
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
