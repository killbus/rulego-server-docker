#!/usr/bin/env bash
#
# Offline guards for the publication-order half of scripts/derive-compatibility-sdk.sh: the tag list read
# through scripts/lib.sh, and the rule that a compatibility record must name the newest published
# generation rather than merely a published one.
#
# A record can match the registry byte for byte and still be one generation behind, and nothing inside the
# recorded bytes shows it: the tag resolves, both architectures agree, and every check that existed before
# this gate is satisfied -- while the compatibility probe quietly proves compatibility with a release nobody
# would call the previous one. So the newest generation is taken from the registry's own tag list and dated
# by the commit each published image names in its config, and every way that answer could be wrong has to be
# a refusal rather than a shorter list.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

mkdir -p "${repository_root}/tmp"
test_root=$(mktemp -d "${repository_root}/tmp/derive-compatibility-order.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/registry" "${test_root}/repo"

sdk_image=$(jq -er '.release.sdk_image' plugin-abi.lock)
self_abi=$(jq -er '.abi_id' plugin-abi.lock)

# Names and digests are computed from the scenario, never typed. An expected digest written into this file
# would be the same kind of transcription the helper under test exists to remove.
abi_id() { printf 'abi-%s\n' "$(printf '%s' "$1" | sha256sum | cut -c1-64)"; }
digest_of() { printf 'sha256:%s\n' "$(printf '%s' "$1" | sha256sum | cut -c1-64)"; }
ref_file() { printf '%s/%s' "${MOCK_REGISTRY_DIR}" "$(printf '%s' "$1" | tr ':@' '__')"; }
config_file() { ref_file "${sdk_image}@$(digest_of "config-$1")"; }

gen_old=$(abi_id old-generation)
gen_mid=$(abi_id middle-generation)
gen_new=$(abi_id newest-generation)
gen_tie=$(abi_id tied-generation)
gen_base=$(abi_id inversion-base)
gen_desc=$(abi_id inversion-descendant)

git_in_repo() {
  (cd "${test_root}/repo" && git -c user.name=order-test -c user.email=order-test@example.invalid "$@")
}

# write_label <identity> <revision-as-the-image-config-says>: the claim a published image makes about where
# it came from, which is the only way a generation can be dated at all.
write_label() {
  jq -cn --arg revision "$2" '{config: {Labels: {"org.opencontainers.image.revision": $revision}}}' \
    >"$(config_file "$1")"
}

# A published generation, as far as this checkout can see it: the index under its canonical name, the same
# index reachable by digest, the linux/amd64 child's config pointer, and that config naming the commit it was
# built from. The annotation on the index and the revision in the config are the two claims a tag name cannot
# witness about itself.
publish() {
  local abi=${1:?a canonical identity is required} revision=${2:?a commit is required}
  local index amd64 arm64 config attestation

  index=$(digest_of "index-${abi}")
  amd64=$(digest_of "amd64-${abi}")
  arm64=$(digest_of "arm64-${abi}")
  config=$(digest_of "config-${abi}")
  attestation=$(digest_of "attestation-${abi}")
  jq -cn --arg digest "${index}" --arg amd64 "${amd64}" --arg arm64 "${arm64}" \
    --arg attestation "${attestation}" --arg abi "${abi}" '
    {digest: $digest, annotations: {"io.rulego.abi.id": $abi}, manifests: [
      {platform: {os: "linux", architecture: "amd64"}, digest: $amd64},
      {platform: {os: "linux", architecture: "arm64"}, digest: $arm64},
      {platform: {os: "unknown", architecture: "unknown"}, digest: $attestation,
       annotations: {"vnd.docker.reference.type": "attestation-manifest"}}]}' |
    tee "$(ref_file "${sdk_image}:${abi}")" >"$(ref_file "${sdk_image}@${index}")"
  jq -cn --arg digest "${config}" '{config: {digest: $digest}}' >"$(ref_file "${sdk_image}@${amd64}")"
  write_label "${abi}" "${revision}"
}

# commit_at stamps both dates, so the timestamps are what the scenario says they are rather than whatever
# the wall clock read while the test ran. The order under test is read from the committer timestamp, and an
# accident of execution time would otherwise be the only thing keeping it honest.
commit_at() {
  local when=${1:?an instant is required} message=${2:?a message is required} stamp
  stamp=$(date -u -d "${when}" +%s)
  ( cd "${test_root}/repo" &&
    GIT_AUTHOR_DATE="@${stamp} +0000" GIT_COMMITTER_DATE="@${stamp} +0000" \
      git -c user.name=order-test -c user.email=order-test@example.invalid commit -q -m "${message}" )
}

# release <instant> <message> <identity>: a commit carrying a lock that records that identity, and the
# generation published from it. The lock has to be in the commit, because the identity is read out of it --
# a scenario that only wrote registry files would pass even if the helper trusted a name it was handed.
release() {
  local when=${1:?an instant is required} message=${2:?a message is required} abi=${3:?a canonical identity is required}
  local revision

  jq -c --arg abi "${abi}" '.abi_id = $abi | del(.compatibility)' plugin-abi.lock \
    >"${test_root}/repo/plugin-abi.lock"
  git_in_repo add plugin-abi.lock
  commit_at "${when}" "${message}"
  revision=$(git_in_repo rev-parse HEAD)
  publish "${abi}" "${revision}"
  printf '%s\n' "${revision}"
}

# The registry stand-in for `docker buildx imagetools inspect`: one file per reference, and an unknown one
# answered as a missing manifest rather than an empty document.
cat >"${test_root}/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} != buildx || ${2:-} != imagetools || ${3:-} != inspect ]]; then
  printf 'unexpected docker call: %s\n' "$*" >&2
  exit 64
fi
file="${MOCK_REGISTRY_DIR}/$(printf '%s' "${4##*/}" | tr ':@' '__')"
if [[ -f ${file} ]]; then
  cat "${file}"
  exit 0
fi
printf 'manifest unknown: %s\n' "$4" >&2
exit 1
STUB

# The stand-in for the tag list. It honours `n=` and `last=` the way the registry does, so a reader that
# asks for one page and calls that the whole repository is caught. MOCK_IGNORE_CURSOR answers every request
# with the first page, which is the failure the cursor-progress guard exists for; MOCK_HTTP_FAIL answers
# nothing at all, because a registry that will not reply must never be read as a repository with no tags;
# and MOCK_FAIL_AFTER answers some pages then stops, which is the shape of a partial answer -- the pages
# that got through still look like a list, and only the page budget knows that the rest is missing.
cat >"${test_root}/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
url=${*: -1}
if [[ -n ${MOCK_HTTP_FAIL:-} ]]; then
  printf 'curl: (22) The requested URL returned error: 502\n' >&2
  exit 22
fi
if [[ ${url} == *"/token?"* ]]; then
  printf '{"token":"mock-token"}\n'
  exit 0
fi
if [[ ${url} == *"/tags/list"* ]]; then
  if [[ -n ${MOCK_FAIL_AFTER:-} ]]; then
    printf 'call\n' >>"${MOCK_PAGE_STATE}"
    if (( $(wc -l <"${MOCK_PAGE_STATE}") > MOCK_FAIL_AFTER )); then
      printf 'curl: (22) The requested URL returned error: 502\n' >&2
      exit 22
    fi
  fi
  if [[ ! -f ${MOCK_TAG_LIST} ]]; then
    printf 'curl: (22) The requested URL returned error: 404\n' >&2
    exit 22
  fi
  # The query is read with regexes rather than parameter patterns, because `&` is a shell token before it
  # is part of a glob, and the first page asks for `n=` with nothing in front of it to anchor on.
  query=${url#*\?}
  n_query='(^|[?&])n=([0-9]+)'
  last_query='(^|[?&])last=([^&]*)'
  page=''
  cursor=''
  if [[ ${query} =~ ${n_query} ]]; then page=${BASH_REMATCH[2]}; fi
  if [[ ${query} =~ ${last_query} ]]; then cursor=${BASH_REMATCH[2]}; fi
  if [[ -z ${page} ]]; then
    printf 'curl stub: a tag list request without a page size: %s\n' "${url}" >&2
    exit 22
  fi
  if [[ -n ${MOCK_IGNORE_CURSOR:-} ]]; then
    cursor=''
  fi
  jq -cn --slurpfile all "${MOCK_TAG_LIST}" --arg cursor "${cursor}" --argjson page "${page}" '
    {tags: ($all[0] |
       if $cursor == "" then . else .[((index($cursor) // 0) + 1):] end |
       .[0:$page])}'
  exit 0
fi
printf 'unexpected curl call: %s\n' "${url}" >&2
exit 22
STUB
chmod +x "${test_root}/bin/docker" "${test_root}/bin/curl"

export MOCK_REGISTRY_DIR=${test_root}/registry
export MOCK_TAG_LIST=${test_root}/tags.json
export MOCK_PAGE_STATE=${test_root}/pages
export PATH=${test_root}/bin:${PATH}
export GITHUB_REPOSITORY_OWNER=killbus
# A registry that will not answer has to be reported after one read, not after the release pipeline's
# eight-attempt backoff.
export REGISTRY_RETRY_ATTEMPTS=1 REGISTRY_RETRY_INITIAL_DELAY=1 REGISTRY_RETRY_MAX_DELAY=1

git_in_repo init -q
git_in_repo commit -q --allow-empty -m before-the-first-release

release '2026-08-26T04:00:00Z' release-2026-08-26 "${gen_old}" >/dev/null
mid_rev=$(release '2026-10-22T04:00:00Z' release-2026-10-22 "${gen_mid}")
new_rev=$(release '2026-10-31T04:00:00Z' release-2026-10-31 "${gen_new}")
# This release's own identity is published too, and cut last. If the order did not exclude it, the answer
# would be this generation: a compatibility record pointing at the release that is being made.
self_rev=$(release '2026-11-01T04:00:00Z' release-of-this-contract "${self_abi}")
# The premise the exclusion is graded on: this contract is cut after the newest published generation, so a
# walk that counted it would answer the release currently being made.
git_in_repo merge-base --is-ancestor "${new_rev}" "${self_rev}" || {
  echo 'the scenario did not cut this contract after the newest published generation' >&2
  exit 1
}

# The list is in ascending date order, so the generation that wins is the last one a walk reaches: a reader
# that stopped early, or that trusted position, or that took every tag for a release, fails here. `latest`
# and a runtime name are in it because the real repository has both.
standard_tags() {
  jq -cn --arg self "${self_abi}" --arg old "${gen_old}" --arg mid "${gen_mid}" --arg new "${gen_new}" \
    '["latest", "v1.0.0-plugin", $self, $old, $mid, $new]' >"${MOCK_TAG_LIST}"
}
standard_tags

current_lock=${test_root}/current.lock
jq -c '.' plugin-abi.lock >"${current_lock}"

helper() { (cd "${test_root}/repo" && PLUGIN_ABI_LOCK="${current_lock}" \
  "${repository_root}/scripts/derive-compatibility-sdk.sh" "$@"); }
previous() { helper previous; }
previous_env() {
  ( cd "${test_root}/repo" && PLUGIN_ABI_LOCK="${current_lock}" \
    env "$@" "${repository_root}/scripts/derive-compatibility-sdk.sh" previous )
}
check_lock() { helper check "$1"; }

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

# The order itself: newest by the commits' own dates, not newest by name, not last in the list, and never
# this release's identity.
answered=$(previous) || {
  echo 'the newest published generation could not be named' >&2
  exit 1
}
IFS=$'\t' read -r answered_tag answered_rev <<<"${answered}"
[[ ${answered_tag} == "${gen_new}" && ${answered_rev} == "${new_rev}" ]] || {
  printf 'the order answered %s at %s, not the newest published generation\n' \
    "${answered_tag:0:12}" "${answered_rev:0:9}" >&2
  exit 1
}

# `derive auto` takes the same answer, so a block cannot be derived from one generation and then refused by
# a gate that insists on another.
derived=$(helper derive auto) || {
  echo 'auto could not derive the newest published generation' >&2
  exit 1
}
jq -e --arg abi "${gen_new}" --arg index "$(digest_of "index-${gen_new}")" \
  --arg amd64 "$(digest_of "amd64-${gen_new}")" --arg arm64 "$(digest_of "arm64-${gen_new}")" \
  --arg repository "ghcr.io/killbus/${sdk_image}" '
  . == {abi_id: $abi, repository: $repository, index_digest: $index,
        children: {amd64: $amd64, arm64: $arm64}}' <<<"${derived}" >/dev/null || {
  printf 'auto derived a block that is not the newest published generation: %s\n' "${derived}" >&2
  exit 1
}

# A record naming the newest generation is accepted, and the acceptance says so out loud: the gate has to be
# readable as a pass, not just as the absence of a failure.
jq --argjson block "${derived}" '.compatibility.previous_sdk = $block' "${current_lock}" \
  >"${test_root}/current-record.lock"
check_lock "${test_root}/current-record.lock" >/dev/null || {
  echo 'the gate refused a record naming the newest published generation' >&2
  exit 1
}

# The case the gate exists for. Every digest in the record is correct, the tag is published, both
# architecture images agree -- and the record names the generation before last. This is exactly what a
# forgotten rotation looks like from inside the lock, and from inside the lock it has always looked fine.
stale=$(helper derive "${mid_rev}") || {
  echo 'the middle generation could not be derived' >&2
  exit 1
}
jq --argjson block "${stale}" '.compatibility.previous_sdk = $block' "${current_lock}" \
  >"${test_root}/stale-record.lock"
refusal 'a record one generation behind' 'is not the newest published generation' \
  check_lock "${test_root}/stale-record.lock"

# A generation whose image names no commit cannot be placed in an order. Skipping it would leave the order
# answering for a list that is missing its newest entry, which is how a stale record starts looking current.
write_label "${gen_new}" 'unlabelled'
refusal 'a published image that does not name its commit' 'does not name the commit' previous
publish "${gen_new}" "${new_rev}"

# A commit that is not in this checkout cannot be dated either. The image reads fine, so nothing else would
# notice, and the generation silently dropped is the one the record should have named.
write_label "${gen_new}" "$(printf 'e%.0s' {1..40})"
refusal 'a published image naming a commit that is not here' 'is not in this checkout' previous
publish "${gen_new}" "${new_rev}"

# A name on the list that does not resolve: the registry has contradicted itself, and after that no answer
# about order is safe to give.
rm -f "$(ref_file "${sdk_image}:${gen_new}")"
refusal 'a listed tag that does not resolve' 'does not resolve' previous
publish "${gen_new}" "${new_rev}"

# Two generations cut in the same second. Dates cannot say which one this release follows, and neither can
# the order of a tag list; choosing by sort position would be a coin flip presented as a finding.
tie_rev=$(release '2026-10-31T04:00:00Z' release-tied-with-the-newest "${gen_tie}")
[[ ${tie_rev} != "${new_rev}" ]] || {
  echo 'the tie scenario cut two generations into one commit' >&2
  exit 1
}
jq -cn --arg self "${self_abi}" --arg old "${gen_old}" --arg mid "${gen_mid}" --arg new "${gen_new}" \
  --arg tie "${gen_tie}" '["latest", $self, $old, $mid, $new, $tie]' >"${MOCK_TAG_LIST}"
refusal 'two published generations in the same second' 'same commit date' previous
standard_tags

# The order the commits disagree with: a generation descending from the newest by date, published with an
# older timestamp. Re-running an older ref overwrites nothing in the registry and would otherwise silently
# reorder the history this record is supposed to follow.
base_rev=$(release '2026-09-10T04:00:00Z' published-later-from-an-older-ref "${gen_base}")
desc_rev=$(release '2026-09-05T04:00:00Z' descending-but-backdated "${gen_desc}")
git_in_repo merge-base --is-ancestor "${base_rev}" "${desc_rev}" || {
  echo 'the inversion scenario did not make the backdated generation a descendant' >&2
  exit 1
}
jq -cn --arg base "${gen_base}" --arg desc "${gen_desc}" '[$base, $desc]' >"${MOCK_TAG_LIST}"
refusal 'a descendant published under an older timestamp' 'descending from it' previous
standard_tags

# The list is walked to the end: two tags a page, six tags in the repository, and the generation that wins
# sits on the last page.
paged=$(previous_env REGISTRY_TAG_PAGE_SIZE=2) || {
  echo 'a paginated tag list was not walked to the end' >&2
  exit 1
}
[[ ${paged} == "${gen_new}"$'\t'"${new_rev}" ]] || {
  printf 'the paginated list answered something other than the newest generation: %s\n' "${paged}" >&2
  exit 1
}

# A registry that ignores the cursor answers the same page twice. Without a progress guard the walk repeats
# forever; the refusal has to name the cursor, because the cursor is the thing that did not work.
refusal 'a registry that ignores the pagination cursor' 'ignored the pagination cursor' \
  previous_env REGISTRY_TAG_PAGE_SIZE=2 MOCK_IGNORE_CURSOR=1

# A page partway through the walk stops answering. The generations before it have already been printed, so
# a reader that trusted what it had would name the newest one it happened to see -- the release before
# last, presented as the predecessor. Nothing about the partial answer looks like a failure, which is why
# this is checked explicitly rather than left to errexit.
rm -f "${MOCK_PAGE_STATE}"
refusal 'a tag list that stops answering before the end' 'would not answer' \
  previous_env REGISTRY_TAG_PAGE_SIZE=2 MOCK_FAIL_AFTER=2

# A repository that does not finish inside the page budget is refused rather than answered with the pages
# that did come back.
refusal 'a tag list that does not finish within the page budget' 'did not finish within' \
  previous_env REGISTRY_TAG_PAGE_SIZE=2 REGISTRY_TAG_PAGE_LIMIT=1

# An unanswered tag list is not an empty repository. Both would leave the order with nothing to name, and
# only one of them means the record is wrong.
refusal 'a tag list the registry would not answer' 'would not answer' \
  previous_env MOCK_HTTP_FAIL=1

# Nothing but this release's own identity is published: there is no predecessor. The gate says so instead of
# accepting a record that points at nothing.
jq -cn --arg self "${self_abi}" '["latest", $self]' >"${MOCK_TAG_LIST}"
refusal 'no published generation other than this one' \
  'nothing for a compatibility record to point at' previous
standard_tags

# A record naming a registry whose tags this script cannot list. Its digests still match, so only the
# ordering half can notice -- and the reason it gives has to be the listing, not an empty list.
jq --arg repository "example.com/killbus/${sdk_image}" \
  '.compatibility.previous_sdk.repository = $repository' "${test_root}/current-record.lock" \
  >"${test_root}/other-host.lock"
refusal 'a record naming a registry whose tags cannot be listed' \
  'tags can only be listed from ghcr.io' check_lock "${test_root}/other-host.lock"

echo 'Publication order refuses to guess when the registry cannot be read to the end'
