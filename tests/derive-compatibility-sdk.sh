#!/usr/bin/env bash
#
# Offline guards for scripts/derive-compatibility-sdk.sh, the rotation helper that replaces a
# hand-transcribed pair of digests.
#
# The block being derived tells the compatibility probe which published SDK image to load. Two of its
# four values are digests nothing in this repository computes, so the old failure mode was a wrong
# digit that every offline check approved -- no offline check can see a registry. The cases below pin
# that the helper refuses to invent an answer, and that the answer it does print is both exact and
# legal at the place it gets pasted.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

source "${repository_root}/tests/helpers.sh"

mkdir -p "${repository_root}/tmp"
test_root=$(mktemp -d "${repository_root}/tmp/derive-compatibility-sdk.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/registry" "${test_root}/repo"

index_digest=sha256:$(printf 'a%.0s' {1..64})
moved_digest=sha256:$(printf 'd%.0s' {1..64})
amd64_child=sha256:$(printf 'b%.0s' {1..64})
arm64_child=sha256:$(printf 'c%.0s' {1..64})
attestation=sha256:$(printf '0%.0s' {1..64})
# The image config of the linux/amd64 child. The helper reads the packaging revision out of it, so the
# mock has to answer for that reference too, not only for the tag and the index.
config_digest=sha256:$(printf '9%.0s' {1..64})

# The revision stands for an earlier release: a published generation with its own identity. It cannot
# be HEAD, because after this contract is committed HEAD *is* the current lock, and a lock may not
# record itself as its own predecessor. Synthesize a predecessor with a different build determinant and
# a recomputed identity so the fixture does not depend on the checkout's commit history.
previous_lock_file=${test_root}/previous.lock
jq '.abi.rulego_server.revision = "b31cbc7963181a5d7d5298d6e03e195a93f498a3"' \
  plugin-abi.lock >"${previous_lock_file}"
refresh_abi_id "${previous_lock_file}"
work_lock=$(cat "${previous_lock_file}")
previous_abi_id=$(jq -er '.abi_id' <<<"${work_lock}")
printf '%s\n' "${work_lock}" >"${test_root}/repo/plugin-abi.lock"
sdk_image=$(jq -er '.distribution.release.sdk_image // .release.sdk_image' \
  "${test_root}/repo/plugin-abi.lock")
# One mock file per reference. The registry stand-in keys on the last path component with `:` and `@`
# turned into `_`, so every writer here has to use the same transform: a tag, an index read by digest
# and an image config are three different references that all live in this one directory.
ref_file() { printf '%s/%s' "${MOCK_REGISTRY_DIR}" "$(printf '%s' "$1" | tr ':@' '__')"; }
reference_file() { ref_file "${sdk_image}:${previous_abi_id}"; }

git_in_repo() {
  (cd "${test_root}/repo" && git -c user.name=derive-test -c user.email=derive-test@example.invalid "$@")
}
git_in_repo init -q
git_in_repo commit -q --allow-empty -m seeded-before-the-contract
git_in_repo add plugin-abi.lock
git_in_repo commit -q -m previous-contract
previous_commit=$(git_in_repo rev-parse HEAD)

# The commit named by an image that this release does not follow. It exists in the synthetic history, so
# a helper that only asked "is this a commit?" would accept it; the claim under test is that the tag
# asked about was not built from it.
other_commit=$(git_in_repo rev-parse HEAD~1)

# A registry stand-in for `docker buildx imagetools inspect`: every reference resolves through a file,
# and MOCK_SEQUENTIAL names a call log so a later read can answer differently from the first. That
# knob exists for the one race this helper cannot otherwise be made to survive -- a tag that moves
# between resolving it and reading the index it resolved to. MOCK_UNREACHABLE models a registry that
# answers at all, which must never be read as an absent tag.
cat >"${test_root}/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} != buildx || ${2:-} != imagetools || ${3:-} != inspect ]]; then
  printf 'unexpected docker call: %s\n' "$*" >&2
  exit 64
fi
reference=$4
if [[ -n ${MOCK_UNREACHABLE:-} ]]; then
  printf 'error getting source repository: connection reset\n' >&2
  exit 2
fi
if [[ -n ${MOCK_SEQUENTIAL:-} ]]; then
  printf 'call\n' >>"${MOCK_SEQUENTIAL}"
  file="${MOCK_REGISTRY_DIR}/response-$(wc -l <"${MOCK_SEQUENTIAL}" | tr -d ' ').json"
else
  file="${MOCK_REGISTRY_DIR}/$(printf '%s' "${reference##*/}" | tr ':@' '__')"
fi
if [[ -f ${file} ]]; then
  cat "${file}"
  exit 0
fi
printf 'manifest unknown: %s\n' "${reference}" >&2
exit 1
STUB
chmod +x "${test_root}/bin/docker"
export MOCK_REGISTRY_DIR=${test_root}/registry
export PATH=${test_root}/bin:${PATH}

# A registry stand-in for the HTTP half of the same promise. Publication order is observable only
# through the tag list, so a helper that cannot list tags cannot say "this is the newest published
# generation" -- and must not get to say it. This one answers the anonymous pull token and one
# repository's tags, and treats anything else as a failed request rather than an empty answer, because
# an empty list is how a missing generation would be mistaken for a released one.
cat >"${test_root}/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
url=${*: -1}
if [[ ${url} == *"ghcr.io/token?"* ]]; then
  printf '{"token":"mock-token"}\n'
  exit 0
fi
if [[ ${url} == */tags/list* ]]; then
  if [[ -n ${MOCK_TAG_LIST:-} && -f ${MOCK_TAG_LIST} ]]; then
    jq -cn --slurpfile all "${MOCK_TAG_LIST}" '{tags: $all[0]}'
    exit 0
  fi
  printf 'no such repository\n' >&2
  exit 22
fi
printf 'unexpected curl call: %s\n' "${url}" >&2
exit 22
STUB
chmod +x "${test_root}/bin/curl"
export MOCK_TAG_LIST=${test_root}/tags.json
# One generation is published in this mock: the one the record points at. `latest` is there because the
# real repository has non-canonical names, and a generation list that took every tag for a release would
# have to die dating one that never was an SDK contract.
jq -cn --arg abi "${previous_abi_id}" '["latest", $abi]' >"${MOCK_TAG_LIST}"
export GITHUB_REPOSITORY_OWNER=killbus
# A registry that will not answer must be reported after one read, not after the release pipeline's
# eight-attempt backoff.
export REGISTRY_RETRY_ATTEMPTS=1 REGISTRY_RETRY_INITIAL_DELAY=1 REGISTRY_RETRY_MAX_DELAY=1

# register <revision> -- publishes the mock generation: the index under its canonical name, the same
# index reachable by digest, the amd64 child's config pointer, and that config naming the commit the
# image was built from. The first two carry the identity as an annotation because that is the only place
# a published name can be checked against what it holds. The attestation member is included because a
# real multi-architecture index always carries one, and a helper that counted it as a platform image
# would report a third child nobody can pull.
register() {
  local revision=${1:?the revision named by the published image is required}
  local arm64=${2:-${arm64_child}}

  jq -cn --arg digest "${index_digest}" --arg amd64 "${amd64_child}" --arg arm64 "${arm64}" \
    --arg attestation "${attestation}" --arg abi "${previous_abi_id}" '
    {digest: $digest, annotations: {"io.rulego.abi.id": $abi}, manifests: [
      {platform: {os: "linux", architecture: "amd64"}, digest: $amd64},
      {platform: {os: "linux", architecture: "arm64"}, digest: $arm64},
      {platform: {os: "unknown", architecture: "unknown"}, digest: $attestation,
       annotations: {"vnd.docker.reference.type": "attestation-manifest"}}]}' |
    tee "$(reference_file)" >"$(ref_file "${sdk_image}@${index_digest}")"
  jq -cn --arg digest "${config_digest}" '{config: {digest: $digest}}' \
    >"$(ref_file "${sdk_image}@${amd64_child}")"
  jq -cn --arg revision "${revision}" \
    '{config: {Labels: {"org.opencontainers.image.revision": $revision}}}' \
    >"$(ref_file "${sdk_image}@${config_digest}")"
}

derive() { (cd "${test_root}/repo" && "${repository_root}/scripts/derive-compatibility-sdk.sh" derive "$@"); }
derive_unreachable() {
  (cd "${test_root}/repo" && MOCK_UNREACHABLE=1 \
    "${repository_root}/scripts/derive-compatibility-sdk.sh" derive HEAD)
}
derive_two_reads() {
  (cd "${test_root}/repo" && MOCK_SEQUENTIAL=${test_root}/calls \
    "${repository_root}/scripts/derive-compatibility-sdk.sh" derive HEAD)
}
check() { (cd "${test_root}/repo" && "${repository_root}/scripts/derive-compatibility-sdk.sh" check "$@"); }
check_ownerless() {
  (cd "${test_root}/repo" && unset GITHUB_REPOSITORY_OWNER &&
    "${repository_root}/scripts/derive-compatibility-sdk.sh" check "$@")
}
check_unreachable() {
  (cd "${test_root}/repo" && MOCK_UNREACHABLE=1 \
    "${repository_root}/scripts/derive-compatibility-sdk.sh" check "$@")
}
check_two_reads() {
  (cd "${test_root}/repo" && MOCK_SEQUENTIAL=${test_root}/calls-check \
    "${repository_root}/scripts/derive-compatibility-sdk.sh" check "$@")
}

refusal() {
  local description=$1 pattern=$2
  shift 2
  if "$@" >"${test_root}/refuse.out" 2>"${test_root}/refuse.err"; then
    printf 'expected a refusal: %s\n' "${description}" >&2
    cat "${test_root}/refuse.out" >&2
    exit 1
  fi
  grep -Fq "${pattern}" "${test_root}/refuse.err" || {
    printf 'the refusal for %s did not say why:\n' "${description}" >&2
    cat "${test_root}/refuse.err" >&2
    exit 1
  }
}

# The happy path, asserted field by field against what the mock registry holds. No expected digest is
# typed into this file, which is the point of the thing under test.
register "${previous_commit}"
derived=$(derive HEAD) || {
  echo 'the helper could not derive a block from a published tag' >&2
  exit 1
}
jq -e --arg abi "${previous_abi_id}" --arg repository "ghcr.io/killbus/${sdk_image}" \
  --arg index "${index_digest}" --arg amd64 "${amd64_child}" --arg arm64 "${arm64_child}" '
  . == {abi_id: $abi, repository: $repository, index_digest: $index,
        children: {amd64: $amd64, arm64: $arm64}}' <<<"${derived}" >/dev/null || {
  printf 'the derived block does not name the published bytes: %s\n' "${derived}" >&2
  exit 1
}

# What it prints must be legal where it is pasted: a block the schema rejects would turn a routine
# rotation into a red release, which is the failure this helper exists to remove, not repackage.
jq --argjson block "${derived}" '.distribution.compatibility.previous_sdk = $block' plugin-abi.lock \
  >"${test_root}/stamped.lock"
PLUGIN_ABI_LOCK=${test_root}/stamped.lock scripts/plugin-abi.sh validate --candidate >/dev/null || {
  echo 'the derived block is not a legal .distribution.compatibility.previous_sdk' >&2
  exit 1
}

# One digest for both architectures is a mislabelled index: the probe would compare one image with
# itself and still call the outcome a compatibility result.
register "${previous_commit}" "${amd64_child}"
refusal 'both architectures sharing one digest' 'mislabelled index' derive HEAD

# A missing platform is not a partial answer to paste now and repair after a red release.
jq -cn --arg digest "${index_digest}" --arg arm64 "${arm64_child}" --arg abi "${previous_abi_id}" '
  {digest: $digest, annotations: {"io.rulego.abi.id": $abi},
   manifests: [{platform: {os: "linux", architecture: "arm64"}, digest: $arm64}]}' \
  >"$(reference_file)"
refusal 'an index without linux/amd64' 'does not hold exactly one linux/amd64' derive HEAD

# A revision that was never published cannot be previous to anything, and that has to be said out loud
# rather than answered with a block of placeholders.
register "${previous_commit}"
mv "$(reference_file)" "${test_root}/stored"
refusal 'a canonical tag that is not published' 'no published SDK tag carries' derive HEAD
mv "${test_root}/stored" "$(reference_file)"

# An unreachable registry is not evidence about availability, and must not be reported as an absent
# tag: one means retry, the other means the revision was never released.
refusal 'a registry that would not answer' 'could not answer' derive_unreachable

# The tag resolved, then moved before the index was read. Handing back the moved digest would send the
# probe to bytes that no longer answer to the name the block records. Both answers carry the honest
# annotation, so the only thing that differs between them is the thing under test.
jq -cn --arg digest "${index_digest}" --arg amd64 "${amd64_child}" --arg arm64 "${arm64_child}" \
  --arg abi "${previous_abi_id}" \
  '{digest: $digest, annotations: {"io.rulego.abi.id": $abi}, manifests: [
     {platform: {os:"linux", architecture:"amd64"}, digest: $amd64},
     {platform: {os:"linux", architecture:"arm64"}, digest: $arm64}]}' \
  >"${MOCK_REGISTRY_DIR}/response-1.json"
jq -cn --arg digest "${index_digest}" --arg amd64 "${amd64_child}" --arg arm64 "${arm64_child}" \
  --arg abi "${previous_abi_id}" \
  '{digest: $digest, annotations: {"io.rulego.abi.id": $abi}, manifests: [
     {platform: {os:"linux", architecture:"amd64"}, digest: $amd64},
     {platform: {os:"linux", architecture:"arm64"}, digest: $arm64}]}' \
  >"${MOCK_REGISTRY_DIR}/response-2.json"
jq -cn --arg digest "${moved_digest}" --arg amd64 "${amd64_child}" --arg arm64 "${arm64_child}" \
  --arg abi "${previous_abi_id}" \
  '{digest: $digest, annotations: {"io.rulego.abi.id": $abi}, manifests: [
     {platform: {os:"linux", architecture:"amd64"}, digest: $amd64},
     {platform: {os:"linux", architecture:"arm64"}, digest: $arm64}]}' \
  >"${MOCK_REGISTRY_DIR}/response-3.json"
refusal 'a tag that moved between the two reads' 'not the digest the tag resolves to' derive_two_reads

# Two naming generations for one identity: the pre-split `abi-<id>` and the recipe-qualified
# `abi-<id>-r<recipe12>`. The record stores only the identity, so an identity answering to two sets of
# bytes does not name one release and is refused rather than guessed. When both names carry the same
# bytes the pre-split name is kept, because that is the name the generation was published under.
recipe_tag="${previous_abi_id}-r$(printf '1%.0s' {1..12})"
write_index() {
  local digest=$1
  jq -cn --arg digest "${digest}" --arg amd64 "${amd64_child}" --arg arm64 "${arm64_child}" \
    --arg abi "${previous_abi_id}" \
    '{digest: $digest, annotations: {"io.rulego.abi.id": $abi}, manifests: [
       {platform: {os:"linux", architecture:"amd64"}, digest: $amd64},
       {platform: {os:"linux", architecture:"arm64"}, digest: $arm64}]}'
}
write_index "${moved_digest}" >"$(ref_file "${sdk_image}:${recipe_tag}")"
jq -cn --arg abi "${previous_abi_id}" --arg tag "${recipe_tag}" '["latest", $abi, $tag]' >"${MOCK_TAG_LIST}"
refusal 'one identity under two names holding different bytes' 'more than one set of bytes' derive HEAD
write_index "${index_digest}" >"$(ref_file "${sdk_image}:${recipe_tag}")"
same_bytes=$(derive HEAD) || die 'the same bytes under both names were refused'
[[ ${same_bytes} == "${derived}" ]] ||
  die "both names holding one generation derived something else: ${same_bytes}"
jq -cn --arg abi "${previous_abi_id}" '["latest", $abi]' >"${MOCK_TAG_LIST}"
rm -f "$(ref_file "${sdk_image}:${recipe_tag}")"

# check mode: the record already in a lock is compared with the registry, which is the half that
# makes a mistyped rotation impossible to ship. The mock registry still holds the published index, so
# the record pasted above has to be accepted as it is, and any single-digit change to it has to be
# refused. The owner is deliberately unset here: the record names the repository it was published to,
# so a check that re-derived the name from the caller would pass while proving nothing about the
# record it was asked about.
record_lock=${test_root}/record.lock
jq --argjson block "${derived}" '.distribution.compatibility.previous_sdk = $block' plugin-abi.lock >"${record_lock}"
check_ownerless "${record_lock}" >/dev/null || {
  echo 'the check refused a record that matches the published index' >&2
  exit 1
}

# The tag resolves to bytes the record does not name: the record was written for a different build.
jq --arg other "${moved_digest}" '.distribution.compatibility.previous_sdk.index_digest = $other' "${record_lock}" \
  >"${test_root}/wrong-index.lock"
refusal 'a record naming a different index than the tag resolves to' 'does not match the registry' \
  check "${test_root}/wrong-index.lock"

# A child digest typed one digit wrong is the exact failure the record used to hide, because every
# offline rule approves a well-formed digest.
for arch in amd64 arm64; do
  jq --arg arch "${arch}" '.distribution.compatibility.previous_sdk.children[$arch] =
      ("sha256:" + ("e" * 64))' "${record_lock}" >"${test_root}/wrong-${arch}.lock"
  refusal "a record naming a different linux/${arch} image" "does not name the published linux/${arch}" \
    check "${test_root}/wrong-${arch}.lock"
done

# The recorded tag was never published, and a registry that will not answer is reported apart from it.
mv "$(reference_file)" "${test_root}/stored"
refusal 'a record naming an unpublished tag' 'is not published' check "${record_lock}"
refusal 'a registry that would not answer a check' 'could not answer' check_unreachable "${record_lock}"
mv "${test_root}/stored" "$(reference_file)"

# The tag resolved, then moved before the index was read: the check would otherwise compare the
# record against bytes it never looked at.
refusal 'a tag that moved between the two reads of a check' 'not the digest the tag resolves to' \
  check_two_reads "${record_lock}"

# The identity comes from the lock at that revision, never from a recomputation here. Recomputing is the
# thing that broke: the identity function's domain changed once, so today's function hashes an older
# contract into a name that generation was never published under, and demanding that it validate against
# today's schema refuses every real predecessor. What remains has to be checked claim by claim, so a lock
# that records no usable identity leaves nothing to check.
git_in_repo rm -q plugin-abi.lock
git_in_repo commit -q -m a-revision-with-no-contract
refusal 'a revision with no lock' 'no plugin-abi.lock' derive HEAD

git_in_repo show "${previous_commit}:plugin-abi.lock" >"${test_root}/restored.lock"
jq 'del(.abi_id)' "${test_root}/restored.lock" >"${test_root}/repo/plugin-abi.lock"
git_in_repo add plugin-abi.lock
git_in_repo commit -q -m a-revision-recording-no-identity
refusal 'a lock that records no identity' 'records no identity' derive HEAD

jq '.abi_id = "abi-not-a-digest"' "${test_root}/restored.lock" >"${test_root}/repo/plugin-abi.lock"
git_in_repo add plugin-abi.lock
git_in_repo commit -q -m a-revision-recording-an-ill-formed-identity
refusal 'a lock recording an identity that is not a digest' 'not an ABI digest' derive HEAD

# The published index annotates an identity other than the tag being derived. A name can be repointed at
# bytes that answer to another contract, and only the content says so: the lock at the revision would keep
# describing the generation the name used to hold.
jq -cn --arg digest "${index_digest}" --arg amd64 "${amd64_child}" --arg arm64 "${arm64_child}" \
  --arg attestation "${attestation}" --arg abi "abi-$(printf '1%.0s' {1..64})" '
  {digest: $digest, annotations: {"io.rulego.abi.id": $abi}, manifests: [
    {platform: {os: "linux", architecture: "amd64"}, digest: $amd64},
    {platform: {os: "linux", architecture: "arm64"}, digest: $arm64},
    {platform: {os: "unknown", architecture: "unknown"}, digest: $attestation,
     annotations: {"vnd.docker.reference.type": "attestation-manifest"}}]}' >"$(reference_file)"
refusal 'an index annotating an identity other than the tag' 'annotates an identity other than' \
  derive "${previous_commit}"

# The three claims below agree on the tag, the annotation and the two architectures, and the image still
# names a commit other than the revision asked about. That generation is not the one this release follows,
# and a record made from it would send the compatibility probe to a predecessor chosen by name alone.
register "${previous_commit}"
jq -cn --arg revision "${other_commit}" \
  '{config: {Labels: {"org.opencontainers.image.revision": $revision}}}' \
  >"$(ref_file "${sdk_image}@${config_digest}")"
refusal 'a published image built from another commit' 'was built from' derive "${previous_commit}"


# --- asking about a generation by its identity ---
#
# A published generation can outlive the commit it names. One of the real ones was cut from a dispatch ref
# that was later rewritten, so no ref of this repository carries its commit -- while the tag resolves, the
# index answers to its own name, and both architectures are there. The identity has to be enough to ask
# with, because it is the only question about such a release that can still be answered, and it is what
# `derive auto` asks when the newest generation is one of these.
foreign_abi="abi-$(printf '2%.0s' {1..64})"
orphan_revision=$(printf 'f%.0s' {1..40})

register "${orphan_revision}"
orphan_block=$(derive "${previous_abi_id}") || {
  echo 'a generation whose commit is not here could not be derived by its identity' >&2
  exit 1
}
jq -e --arg abi "${previous_abi_id}" --arg repository "ghcr.io/killbus/${sdk_image}" \
  --arg index "${index_digest}" --arg amd64 "${amd64_child}" --arg arm64 "${arm64_child}" \
  '. == {abi_id: $abi, repository: $repository, index_digest: $index,
         children: {amd64: $amd64, arm64: $arm64}}' <<<"${orphan_block}" >/dev/null || {
  printf 'deriving by identity did not answer with the published bytes: %s\n' "${orphan_block}" >&2
  exit 1
}

# The same generation asked about by revision is still refused. Naming a source is asking whether the bytes
# came from it, and "that commit is not here" is not an answer to the question that was asked -- it is only a
# reason to stop asking it.
refusal 'a revision whose published image cites another commit' 'was built from' \
  derive "${previous_commit}"

# When the cited commit IS here it is a witness, not an option. This one is in the synthetic history and
# carries no contract at all: the name, the annotation and the digests all agree, and the generation's own
# source contradicts it. Deriving from that would paste a mismatch into a release record.
register "${other_commit}"
refusal 'a published generation citing a commit with no contract here' \
  'carries no plugin ABI identity' derive "${previous_abi_id}"

# And a commit that is here, does carry a contract, and records a different identity: the same claim refused
# with the two names side by side, which is what an operator has to read in order to tell an orphan from a
# repointed tag.
jq -c --arg abi "${foreign_abi}" '.abi_id = $abi' "${test_root}/restored.lock" \
  >"${test_root}/repo/plugin-abi.lock"
git_in_repo add plugin-abi.lock
git_in_repo commit -q -m a-revision-recording-another-identity
foreign_commit=$(git_in_repo rev-parse HEAD)
register "${foreign_commit}"
refusal 'a published generation citing a commit that records another identity' 'instead' \
  derive "${previous_abi_id}"

# With the commit it cites present and agreeing, the identity question and the revision question return the
# same bytes: one path is not stricter than the other, it only asks less of history.
register "${previous_commit}"
asserted=$(derive "${previous_abi_id}") || {
  echo 'the identity path refused a generation whose commit is here and agrees' >&2
  exit 1
}
by_revision=$(derive "${previous_commit}") || {
  echo 'the revision path refused a generation it used to derive' >&2
  exit 1
}
[[ ${asserted} == "${by_revision}" ]] || {
  echo 'the identity path and the revision path returned different blocks for one generation' >&2
  exit 1
}
echo 'Compatibility SDK rotation derives from the registry and refuses to invent one'
