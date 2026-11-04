#!/usr/bin/env bash
# shellcheck disable=SC2016
# Canonical-name backfill, offline.
#
# The writer talks to GHCR, which no offline suite can reach, so what is pinned here is the part that
# can go wrong in silence: a plan that names bytes other than the ones it describes, a name that the
# naming function does not produce, a target that already holds something else, and the difference
# between "the registry says no" and "the registry could not answer". The expensive failure is a
# backfill that quietly re-points a published name, so most branches below aim at that one.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

mkdir -p "${repository_root}/tmp"
test_root=$(mktemp -d "${repository_root}/tmp/plugin-abi-backfill.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/registry"

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

# Same key the `docker` stub derives: registry host and repository path are dropped, so a reference
# and its file name agree in both places.
reference_file() { printf '%s' "${1##*/}" | tr ':@' '__'; }

repo=ghcr.io/killbus/rulego-server
# `HEAD` is the one commit every checkout has, shallow included, and the writer only asks that a plan's
# revision resolve here at all. Ancestor commits would work too but assume history this suite does not
# need to assume to test the gate.
revision=$(git rev-parse HEAD)
[[ ${revision} =~ ^[0-9a-f]{40}$ ]] || die 'no commit to build a plan from'
tags=$(PLUGIN_ABI_NAME_REVISION="${revision}" ./scripts/plugin-abi.sh render tags)
host=plugin
# `render tags` yields `<image>:<tag>` per name, so the tag is split off before the repository is
# prepended. Getting this wrong puts the image name in the tag twice, which is exactly the shape a
# careless plan would have.
canonical_tag=$(jq -er --arg h "${host}" '.runtime[$h].canonical' <<<"${tags}")
canonical_tag=${canonical_tag#*:}
alias_tag=$(jq -er --arg h "${host}" '.runtime[$h].alias' <<<"${tags}")
alias_tag=${alias_tag#*:}
canonical=${repo}:${canonical_tag}
alias_ref=${repo}:${alias_tag}
[[ ${canonical} != "${alias_ref}" ]] || die 'the derived canonical name is the alias, so nothing to test'

cast_digest=sha256:$(printf 'c%.0s' {1..64})
other_digest=sha256:$(printf 'f%.0s' {1..64})
child_digest=sha256:$(printf 'd%.0s' {1..64})
config_digest=sha256:$(printf 'e%.0s' {1..64})
release_version=$(jq -er '.abi.rulego_server.release_version' plugin-abi.lock)

# `docker buildx imagetools inspect` resolves through files, and `create` records its arguments so a
# later case can assert that nothing was written, or that exactly one write happened with the plan's
# own tag and source. A registry that will not answer is a distinct mode: it must never be read as an
# absent name.
cat >"${test_root}/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == buildx && ${2:-} == imagetools && ${3:-} == inspect ]]; then
  reference=$4
  if [[ -n ${MOCK_TAG_UNREACHABLE:-} && ${reference} != *@* ]]; then
    printf 'error getting source repository: read connection reset by peer\n' >&2
    exit 2
  fi
  if [[ -n ${MOCK_UNREACHABLE:-} ]]; then
    printf 'error getting source repository: read connection reset by peer\n' >&2
    exit 2
  fi
  file="${MOCK_REGISTRY_DIR}/$(printf '%s' "${reference##*/}" | tr ':@' '__')"
  if [[ -f ${file} ]]; then
    cat "${file}"
    exit 0
  fi
  printf 'manifest unknown: %s\n' "${reference}" >&2
  exit 1
fi
if [[ ${1:-} == buildx && ${2:-} == imagetools && ${3:-} == create ]]; then
  [[ ${4:-} == --tag ]] || { printf 'unexpected create form: %s\n' "$*" >&2; exit 64; }
  printf '%s\t%s\n' "$5" "$6" >>"${MOCK_WRITES}"
  jq -cn --arg digest "${6##*@}" '{digest: $digest, manifests: [], annotations: {}}' \
    >"${MOCK_REGISTRY_DIR}/$(printf '%s' "${5##*/}" | tr ':@' '__')"
  exit 0
fi
printf 'unexpected docker call: %s\n' "$*" >&2
exit 64
STUB
chmod +x "${test_root}/bin/docker"
export MOCK_REGISTRY_DIR=${test_root}/registry
export MOCK_WRITES=${test_root}/writes
export PATH=${test_root}/bin:${PATH}
export REGISTRY_RETRY_ATTEMPTS=1 REGISTRY_RETRY_INITIAL_DELAY=1 REGISTRY_RETRY_MAX_DELAY=1

# register_cast <index-digest> <label-revision> <release-annotation>
# Writes the three objects the writer reads: the index, its amd64 child manifest, and that child's
# config, which is where the packaging revision lives.
register_cast() {
  local digest=$1 label_revision=$2 annotation=$3
  jq -cn --arg digest "${digest}" --arg child "${child_digest}" --arg other "${other_digest}" \
    --arg release "${annotation}" \
    '{digest: $digest,
      manifests: [
        {platform: {os: "linux", architecture: "amd64"}, digest: $child},
        {platform: {os: "linux", architecture: "arm64"}, digest: $other}],
      annotations: {"io.rulego.server.release": $release}}' \
    >"${MOCK_REGISTRY_DIR}/$(reference_file "${repo}@${digest}")"
  jq -cn --arg config "${config_digest}" '{config: {digest: $config}}' \
    >"${MOCK_REGISTRY_DIR}/$(reference_file "${repo}@${child_digest}")"
  jq -cn --arg revision "${label_revision}" \
    '{config: {Labels: {"org.opencontainers.image.revision": $revision}}}' \
    >"${MOCK_REGISTRY_DIR}/$(reference_file "${repo}@${config_digest}")"
}

# write_plan <canonical-tag> <digest> <revision> <alias-tag> <host> <repository>
write_plan() {
  jq -cn --arg c "$1" --arg d "$2" --arg r "$3" --arg a "$4" --arg h "$5" --arg repo "$6" '
    {schema_version: 1,
     entries: [{host: $h, digest: $d, packaging_revision: $r,
               canonical_ref: ($repo + ":" + $c), displaced_alias: ($repo + ":" + $a)}]}'     >"${test_root}/plan.json"
}

run_writer() {
  local mode=$1
  PLUGIN_ABI_BACKFILL_PLAN=${test_root}/plan.json \
  PLUGIN_ABI_BACKFILL_RECORD=${test_root}/report.json \
  GITHUB_REPOSITORY_OWNER=killbus \
    ./scripts/backfill-runtime-canonicals.sh "${mode}"
}

expect_refusal() {
  local description=$1 needle=$2 status=0 output
  : >"${MOCK_WRITES}"
  output=$(run_writer check 2>&1) || status=$?
  (( status != 0 )) || die "${description}: accepted a plan it must refuse"
  grep -Fq -- "${needle}" <<<"${output}" ||
    die "${description}: refused for the wrong reason: ${output}"
  [[ -s ${MOCK_WRITES} ]] && die "${description}: wrote despite the refusal"
  return 0
}

# A free name is the only state that may be minted.
: >"${MOCK_WRITES}"
register_cast "${cast_digest}" "${revision}" "${release_version}"
write_plan "${canonical_tag}" "${cast_digest}" "${revision}" "${alias_tag}" "${host}" "${repo}"
status=0
out=$(run_writer check 2>&1) || status=$?
(( status == 0 )) || die "a valid plan with a free name was refused: ${out}"
[[ $(jq -er '.entries[0].action' "${test_root}/report.json") == mint ]] ||
  die 'a free name was not reported as a write candidate'
[[ $(jq -er '.entries[0].digest_matches' "${test_root}/report.json") == false ]] ||
  die 'check mode claimed the bytes were already in place'
[[ ! -s ${MOCK_WRITES} ]] || die 'check mode wrote'

# apply without the acknowledgement must refuse before it asks the registry anything.
status=0
out=$(PLUGIN_ABI_BACKFILL_PLAN=${test_root}/plan.json PLUGIN_ABI_BACKFILL_RECORD=${test_root}/report.json \
  GITHUB_REPOSITORY_OWNER=killbus ./scripts/backfill-runtime-canonicals.sh apply 2>&1) || status=$?
(( status != 0 )) || die 'apply ran without PLUGIN_ABI_BACKFILL_APPLY'
grep -Fq 'PLUGIN_ABI_BACKFILL_APPLY' <<<"${out}" || die "apply refused for the wrong reason: ${out}"
[[ ! -s ${MOCK_WRITES} ]] || die 'apply wrote without the acknowledgement'

# apply with it: one create, with the plan's own name and the plan's own bytes.
status=0
out=$(PLUGIN_ABI_BACKFILL_APPLY=1 run_writer apply 2>&1) || status=$?
(( status == 0 )) || die "apply failed: ${out}"
[[ $(wc -l <"${MOCK_WRITES}") == 1 ]] || die 'apply wrote more than once'
IFS=$'\t' read -r written_tag written_src <"${MOCK_WRITES}"
[[ ${written_tag} == "${canonical}" ]] || die 'apply wrote a tag the plan does not name'
[[ ${written_src} == "${repo}@${cast_digest}" ]] || die 'apply wrote a source the plan does not name'
[[ $(jq -er '.entries[0].digest_matches' "${test_root}/report.json") == true ]] ||
  die 'apply reported without reading the name back'
# And the answer has to be about the registry, not about the record: read what the stand-in now
# resolves for that name. A writer that trusted `create` exiting zero would pass the assertion above
# and fail this one.
resolved=$(jq -er '.digest' "${MOCK_REGISTRY_DIR}/$(reference_file "${canonical}")")
[[ ${resolved} == "${cast_digest}" ]] || die 'the name written does not hold the bytes the plan named'

# A second apply finds the name already holding these bytes and writes nothing.
: >"${MOCK_WRITES}"
status=0
out=$(PLUGIN_ABI_BACKFILL_APPLY=1 run_writer apply 2>&1) || status=$?
(( status == 0 )) || die "the idempotent second apply failed: ${out}"
[[ $(jq -er '.entries[0].action' "${test_root}/report.json") == noop ]] ||
  die 'the second apply did not report a no-op'
[[ ! -s ${MOCK_WRITES} ]] || die 'the idempotent apply wrote again'

# A name that already holds other bytes is never moved.
rm -f "${MOCK_REGISTRY_DIR}/$(reference_file "${canonical}")"
jq -cn --arg digest "${other_digest}" '{digest: $digest, manifests: [], annotations: {}}' \
  >"${MOCK_REGISTRY_DIR}/$(reference_file "${canonical}")"
expect_refusal 'taken name' 'already holds other bytes'

# The plan has to describe the bytes it names, in both directions.
rm -f "${MOCK_REGISTRY_DIR}/$(reference_file "${canonical}")"
register_cast "${cast_digest}" "$(printf 'b%.0s' {1..40})" "${release_version}"
expect_refusal 'bytes carry another revision' 'different packaging revision'
register_cast "${cast_digest}" "${revision}" v0.37.0
expect_refusal 'bytes belong to another release' 'release v0.37.0'
register_cast "${cast_digest}" "${revision}" "${release_version}"

# A name the naming function does not produce, in the repository it does not publish, and a host it
# does not lock, are all refusals that need no registry at all.
write_plan "${canonical_tag}-extra" "${cast_digest}" "${revision}" "${alias_tag}" "${host}" "${repo}"
expect_refusal 'invented name' 'the naming function produces'
write_plan "${canonical_tag}" "${cast_digest}" "${revision}" "${alias_tag}" "${host}" ghcr.io/killbus/elsewhere
expect_refusal 'wrong repository' 'publishes nothing'
write_plan "${canonical_tag}" "${cast_digest}" "${revision}" "${alias_tag}" not-a-host "${repo}"
expect_refusal 'host outside the lock' 'not a host of the current lock'
write_plan "${canonical_tag}" not-a-digest "${revision}" "${alias_tag}" "${host}" "${repo}"
expect_refusal 'malformed digest' 'not a sha256'
write_plan "${canonical_tag}" "${cast_digest}" "$(printf '0%.0s' {1..40})" "${alias_tag}" "${host}" "${repo}"
expect_refusal 'revision outside this checkout' 'not a commit of this checkout'
write_plan "${canonical_tag}" "${cast_digest}" "${revision}" "${canonical_tag}" "${host}" "${repo}"
expect_refusal 'alias rewritten to the canonical' 'the alias for that revision is'

# A registry that cannot answer at all is not a free name.
register_cast "${cast_digest}" "${revision}" "${release_version}"
write_plan "${canonical_tag}" "${cast_digest}" "${revision}" "${alias_tag}" "${host}" "${repo}"
status=0
: >"${MOCK_WRITES}"
out=$(MOCK_UNREACHABLE=1 run_writer check 2>&1) || status=$?
(( status != 0 )) || die 'an unreachable registry was treated as absence'
grep -Fq 'could not answer' <<<"${out}" || die "unreachable handled wrongly: ${out}"
[[ ! -s ${MOCK_WRITES} ]] || die 'an unreachable registry still wrote'

# The sharper case: the registry can describe the bytes and cannot answer about the name. That is the
# one place where "I do not know" is most tempting to read as "nobody holds it", and it is exactly the
# question a write depends on.
status=0
out=$(MOCK_TAG_UNREACHABLE=1 run_writer check 2>&1) || status=$?
(( status != 0 )) || die 'a name the registry could not answer about was treated as absent'
grep -Fq 'could not answer whether the name exists' <<<"${out}" ||
  die "name-lookup failure handled wrongly: ${out}"
[[ ! -s ${MOCK_WRITES} ]] || die 'a name lookup failure still wrote'

# The committed plan is graded offline as well: every name it carries is what the naming function
# produces for the revision that image itself carries, and the set of names is exactly the set the
# displaced aliases imply.
[[ -f plugin-abi-backfill.json ]] || die 'no committed backfill plan'
# The plan cites the commits its images were built from, and the writer refuses any plan whose revision
# it cannot resolve in this checkout. That is a real gate on real writes, so it is not relaxed for a
# shallow clone; instead the suite says which assumption broke, rather than letting the writer report a
# correct plan as an invented one.
while IFS= read -r plan_revision; do
  git cat-file -e "${plan_revision}^{commit}" 2>/dev/null \
    || die "the plan cites ${plan_revision}, which this checkout does not have: run git fetch --unshallow"
done < <(jq -r '.entries[].packaging_revision' plugin-abi-backfill.json)
derivation=$(PLUGIN_ABI_BACKFILL_PLAN=plugin-abi-backfill.json \
  PLUGIN_ABI_BACKFILL_RECORD=${test_root}/committed.json \
  GITHUB_REPOSITORY_OWNER=killbus ./scripts/backfill-runtime-canonicals.sh derivation-only) ||
  die "the committed plan does not derive: ${derivation}"
[[ $(jq -r '.entries | length' plugin-abi-backfill.json) == 2 ]] ||
  die 'the committed plan does not cover both displaced casts'
[[ $(jq -e '[.entries[].action] | all(. == "derived")' "${test_root}/committed.json") ]] ||
  die 'the committed-plan report did not describe derivation only'
jq -r '.entries[] | [.host, .packaging_revision, .canonical_ref, .displaced_alias] | @tsv' \
  plugin-abi-backfill.json >"${test_root}/committed-rows.tsv"
while IFS=$'\t' read -r entry_host entry_revision entry_canonical entry_alias; do
  derived=$(PLUGIN_ABI_NAME_REVISION="${entry_revision}" ./scripts/plugin-abi.sh render tags)
  entry_want=$(jq -er --arg h "${entry_host}" '.runtime[$h].canonical' <<<"${derived}")
  [[ ${entry_canonical} == *":${entry_want#*:}" ]] ||
    die "committed plan: ${entry_host} names something the function does not produce"
  entry_alias_want=$(jq -er --arg h "${entry_host}" '.runtime[$h].alias' <<<"${derived}")
  [[ ${entry_alias} == *":${entry_alias_want#*:}" ]] ||
    die "committed plan: ${entry_host} was not displaced from the alias its revision implies"
done <"${test_root}/committed-rows.tsv"
duplicates=$(jq -r '[.entries[].canonical_ref] | length' plugin-abi-backfill.json)
unique=$(jq -r '[.entries[].canonical_ref] | unique | length' plugin-abi-backfill.json)
(( duplicates == unique )) || die 'the committed plan names one target twice'
# No target may be one of the moving names, compared on the tag part alone.
live_aliases=$(jq -c '[.runtime[].alias | split(":")[1]]' <<<"${tags}")
jq -e --argjson aliases "${live_aliases}" '
  [ .entries[].canonical_ref | split(":")[1] ]
  | any(. as $tag | $aliases | index($tag) != null) | not' plugin-abi-backfill.json >/dev/null ||
  die 'the committed plan would make a moving name immutable'

printf 'canonical-name backfill plan, refusals, idempotence, and committed derivations passed\n'
