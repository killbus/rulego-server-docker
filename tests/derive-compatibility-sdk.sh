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

mkdir -p "${repository_root}/tmp"
test_root=$(mktemp -d "${repository_root}/tmp/derive-compatibility-sdk.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/registry" "${test_root}/repo"

index_digest=sha256:$(printf 'a%.0s' {1..64})
moved_digest=sha256:$(printf 'd%.0s' {1..64})
amd64_child=sha256:$(printf 'b%.0s' {1..64})
arm64_child=sha256:$(printf 'c%.0s' {1..64})
attestation=sha256:$(printf '0%.0s' {1..64})

# The revision stands for an earlier release: the same contract shape, one different packaging
# generation, therefore a different identity. It cannot be HEAD, because a lock may not record itself
# as its own predecessor; pasting HEAD's identity would only ever exercise that schema rule.
work_lock=$(git show HEAD:plugin-abi.lock)
previous_abi_id=$(jq -S -c '.abi | .packaging.version = "9"' <<<"${work_lock}" | tr -d '\r' |
  { sha256sum | awk '{print "abi-" $1}'; })
jq -S --arg abi_id "${previous_abi_id}" '.abi.packaging.version = "9" | .abi_id = $abi_id' \
  <<<"${work_lock}" >"${test_root}/repo/plugin-abi.lock"
sdk_image=$(jq -er '.release.sdk_image' "${test_root}/repo/plugin-abi.lock")
reference_file() { printf '%s' "${MOCK_REGISTRY_DIR}/${sdk_image}:${previous_abi_id}" | tr ':@' '__'; }

git_in_repo() {
  (cd "${test_root}/repo" && git -c user.name=derive-test -c user.email=derive-test@example.invalid "$@")
}
git_in_repo init -q
git_in_repo commit -q --allow-empty -m seeded-before-the-contract
git_in_repo add plugin-abi.lock
git_in_repo commit -q -m previous-contract

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
export GITHUB_REPOSITORY_OWNER=killbus
# A registry that will not answer must be reported after one read, not after the release pipeline's
# eight-attempt backoff.
export REGISTRY_RETRY_ATTEMPTS=1 REGISTRY_RETRY_INITIAL_DELAY=1 REGISTRY_RETRY_MAX_DELAY=1

# register <index-digest> <amd64> <arm64> -- writes what the published index holds. The attestation
# member is included because a real multi-architecture index always carries one, and a helper that
# counted it as a platform image would report a third child nobody can pull.
register() {
  jq -cn --arg digest $1 --arg amd64 $2 --arg arm64 $3 --arg attestation "${attestation}" '
    {digest: $digest, manifests: [
      {platform: {os: "linux", architecture: "amd64"}, digest: $amd64},
      {platform: {os: "linux", architecture: "arm64"}, digest: $arm64},
      {platform: {os: "unknown", architecture: "unknown"}, digest: $attestation,
       annotations: {"vnd.docker.reference.type": "attestation-manifest"}}]}' >"$(reference_file)"
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
register "${index_digest}" "${amd64_child}" "${arm64_child}"
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
jq --argjson block "${derived}" '.compatibility.previous_sdk = $block' plugin-abi.lock \
  >"${test_root}/stamped.lock"
PLUGIN_ABI_LOCK=${test_root}/stamped.lock scripts/plugin-abi.sh validate --candidate >/dev/null || {
  echo 'the derived block is not a legal .compatibility.previous_sdk' >&2
  exit 1
}

# One digest for both architectures is a mislabelled index: the probe would compare one image with
# itself and still call the outcome a compatibility result.
register "${index_digest}" "${amd64_child}" "${amd64_child}"
refusal 'both architectures sharing one digest' 'mislabelled index' derive HEAD

# A missing platform is not a partial answer to paste now and repair after a red release.
jq -cn --arg digest "${index_digest}" --arg arm64 "${arm64_child}" '
  {digest: $digest, manifests: [{platform: {os: "linux", architecture: "arm64"}, digest: $arm64}]}' \
  >"$(reference_file)"
refusal 'an index without linux/amd64' 'does not hold exactly one linux/amd64' derive HEAD

# A revision that was never published cannot be previous to anything, and that has to be said out loud
# rather than answered with a block of placeholders.
register "${index_digest}" "${amd64_child}" "${arm64_child}"
mv "$(reference_file)" "${test_root}/stored"
refusal 'a canonical tag that is not published' 'no published SDK tag to derive' derive HEAD
mv "${test_root}/stored" "$(reference_file)"

# An unreachable registry is not evidence about availability, and must not be reported as an absent
# tag: one means retry, the other means the revision was never released.
refusal 'a registry that would not answer' 'could not answer' derive_unreachable

# The tag resolved, then moved before the index was read. Handing back the moved digest would send the
# probe to bytes that no longer answer to the name the block records.
jq -cn --arg digest "${index_digest}" --arg amd64 "${amd64_child}" --arg arm64 "${arm64_child}" \
  '{digest: $digest, manifests: [
     {platform: {os:"linux", architecture:"amd64"}, digest: $amd64},
     {platform: {os:"linux", architecture:"arm64"}, digest: $arm64}]}' \
  >"${MOCK_REGISTRY_DIR}/response-1.json"
jq -cn --arg digest "${moved_digest}" --arg amd64 "${amd64_child}" --arg arm64 "${arm64_child}" \
  '{digest: $digest, manifests: [
     {platform: {os:"linux", architecture:"amd64"}, digest: $amd64},
     {platform: {os:"linux", architecture:"arm64"}, digest: $arm64}]}' \
  >"${MOCK_REGISTRY_DIR}/response-2.json"
refusal 'a tag that moved between the two reads' 'not the digest the tag resolves to' derive_two_reads

# check mode: the record already in a lock is compared with the registry, which is the half that
# makes a mistyped rotation impossible to ship. The mock registry still holds the published index, so
# the record pasted above has to be accepted as it is, and any single-digit change to it has to be
# refused. The owner is deliberately unset here: the record names the repository it was published to,
# so a check that re-derived the name from the caller would pass while proving nothing about the
# record it was asked about.
record_lock=${test_root}/record.lock
jq --argjson block "${derived}" '.compatibility.previous_sdk = $block' plugin-abi.lock >"${record_lock}"
check_ownerless "${record_lock}" >/dev/null || {
  echo 'the check refused a record that matches the published index' >&2
  exit 1
}

# The tag resolves to bytes the record does not name: the record was written for a different build.
jq --arg other "${moved_digest}" '.compatibility.previous_sdk.index_digest = $other' "${record_lock}" \
  >"${test_root}/wrong-index.lock"
refusal 'a record naming a different index than the tag resolves to' 'does not match the registry' \
  check "${test_root}/wrong-index.lock"

# A child digest typed one digit wrong is the exact failure the record used to hide, because every
# offline rule approves a well-formed digest.
for arch in amd64 arm64; do
  jq --arg arch "${arch}" '.compatibility.previous_sdk.children[$arch] =
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

# The identity comes from the lock at that revision, never from the caller, so a revision whose lock
# is not a legal contract has nothing to derive. Two shapes: no lock at all, and a lock whose recorded
# identity does not match its own bytes.
git_in_repo rm -q plugin-abi.lock
git_in_repo commit -q -m a-revision-with-no-contract
refusal 'a revision with no lock' 'no plugin-abi.lock' derive HEAD

git_in_repo show 'HEAD~1:plugin-abi.lock' >"${test_root}/restored.lock"
jq '.abi_id = ("abi-" + ("f" * 64))' "${test_root}/restored.lock" >"${test_root}/stale.lock"
mv "${test_root}/stale.lock" "${test_root}/repo/plugin-abi.lock"
git_in_repo add plugin-abi.lock
git_in_repo commit -q -m a-revision-with-a-stale-identity
refusal 'a revision whose lock is not a contract' 'not a valid Plugin ABI contract' derive HEAD

echo 'Compatibility SDK rotation derives from the registry and refuses to invent one'
