#!/usr/bin/env bash
# shellcheck disable=SC2016
# Canonical tag allocatability, offline.
# Canonical tag allocatability, offline.
#
# The probe talks to GHCR, which no offline suite can reach, so what is asserted here is the part
# that can be wrong in silence: how a probe result is classified, and which names the probe asks
# about at all. The most expensive failure to ship would be an occupied name reported as free,
# because that turns a blocked release into a green pull request; every branch below is aimed at
# that, and the plan comparison at the end exists so the probe cannot be asked about a different
# set of names than publication writes.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${repository_root}/scripts/lib.sh"

mkdir -p "${repository_root}/tmp"
test_root=$(mktemp -d "${repository_root}/tmp/canonical-tag-allocatability.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

this_abi=abi-7ef7f30db8598b7fdce710287df49bdb047d165749b749fe86c0ef448daf0c3f
previous_abi=abi-3e0c9d46dddaf6235cfe609d543222f07f8e1abf3374f0669bf703df85063885
other_abi=abi-0000000000000000000000000000000000000000000000000000000000000001

verdict_case() {
  local description=$1 probe_status=$2 held_by=$3 expected=$4 actual
  actual=$(canonical_tag_verdict "${probe_status}" "${held_by}" "${this_abi}" "${previous_abi}") ||
    die "${description}: classification failed instead of answering"
  [[ ${actual} == "${expected}" ]] ||
    die "${description}: expected ${expected}, found ${actual}"
}

# A name nothing holds is the only state that may be called allocatable.
verdict_case 'unheld name' absent '' allocatable
# Occupancy is never resolved by "does not match this lock": the holder has to be accounted for,
# which is the difference between a derived verdict and a hand-kept allowlist.
verdict_case 'held by this contract' occupied "${this_abi}" republish
verdict_case 'held by the contract this lock replaced' occupied "${previous_abi}" superseded
verdict_case 'held by an unaccounted identity' occupied "${other_abi}" collision
# An index published before this annotation existed carries no identity, so it cannot be derived
# as a predecessor. It is a collision, not a free name and not a silent pass.
verdict_case 'held by an unlabelled index' occupied unlabelled collision
# A registry that could not answer is not evidence of availability.
verdict_case 'registry could not answer' unreachable '' unreachable

# A status the probe cannot emit is rejected rather than defaulted, so a future probe that adds a
# state cannot fall through to allocatable.
if (canonical_tag_verdict invented '' "${this_abi}" "${previous_abi}") >"${test_root}/unknown" 2>&1; then
  echo 'an invented probe status was accepted' >&2
  exit 1
fi
grep -Fq 'unknown canonical tag probe status' "${test_root}/unknown"

# The probe itself: it writes nothing and compares no digest, so only the mock transport is
# exercised here and the real one in CI, where the registry answers.
image_reference_digest() {
  case ${MOCK_PROBE:?} in
    free) return 1 ;;
    transport-error) return 2 ;;
    occupied | unlabelled | broken-index) printf 'sha256:%s\n' "${other_abi#abi-}" ;;
  esac
}

docker() {
  case ${MOCK_PROBE} in
    occupied) printf '{"annotations":{"io.rulego.abi.id":"%s"}}\n' "${previous_abi}" ;;
    unlabelled) printf '{"annotations":{"io.rulego.core.version":"v1.0.0"}}\n' ;;
    broken-index) printf 'not json at all\n' ;;
    *) return 1 ;;
  esac
}

# probe_case <mock> <expected status> <expected holder>
probe_case() {
  local mock=$1 expected_status=$2 expected_holder=$3 out status holder
  MOCK_PROBE=${mock}
  # The malformed-index case makes jq complain on stderr by construction. That noise is captured
  # and asserted rather than left to scroll past a real failure, because a suite that always prints
  # errors teaches nobody to read them.
  out=$(canonical_tag_probe ghcr.io/killbus/rulego-server:v1.0.0-plugin \
    2>"${test_root}/${mock}.stderr") ||
    die "${mock}: probe failed instead of returning a status"
  IFS=$'\t' read -r status holder <<<"${out}"
  [[ ${status} == "${expected_status}" ]] ||
    die "${mock}: expected status ${expected_status}, found ${status}"
  [[ ${holder} == "${expected_holder}" ]] ||
    die "${mock}: expected holder [${expected_holder}], found [${holder}]"
}

probe_case free absent ''
probe_case occupied occupied "${previous_abi}"
probe_case unlabelled occupied unlabelled
# The tag resolved but its index could not be read: unprobed, never absent. This is the branch
# where a careless implementation would report a free name.
probe_case broken-index unreachable ''
[[ -s ${test_root}/broken-index.stderr ]] ||
  die 'the malformed index was read without jq objecting, so the probe did not really parse it'
probe_case transport-error unreachable ''

# Every classification the probe can produce, run through the verdict in one pass, so a status and
# a holder that only combine correctly together are covered as pairs rather than as samples.
while IFS=$'\t' read -r mock expected_verdict; do
  # Without this the loop would probe whatever the previous case left in the mock, and the pairs
  # would be asserted against a state they never asked for.
  MOCK_PROBE=${mock}
  # stderr is set aside here because the dedicated probe_case above already asserts that the
  # malformed index really was parsed and rejected; replaying it should not train the reader to
  # expect errors on a green run.
  out=$(canonical_tag_probe "ghcr.io/killbus/rulego-server:v1.0.0-plugin" \
    2>"${test_root}/pairs-${mock}.stderr")
  IFS=$'\t' read -r status holder <<<"${out}"
  verdict=$(canonical_tag_verdict "${status}" "${holder}" "${this_abi}" "${previous_abi}")
  [[ ${verdict} == "${expected_verdict}" ]] ||
    die "pair ${mock}: expected verdict ${expected_verdict}, found ${verdict}"
done <<PAIRS
free	allocatable
occupied	superseded
unlabelled	collision
broken-index	unreachable
transport-error	unreachable
PAIRS

# The plan the probe walks must be the set of names publication writes. Publication builds its
# canonical targets inline from the same rendered tags, the same owner and the same repository
# derivation; this asserts the derivation in `canonical_tag_plan` reproduces those exact strings,
# so neither side can drift into reporting on a name the other never touches.
tags=$("${repository_root}/scripts/plugin-abi.sh" render tags --candidate)
owner=killbus
sdk_name=$(jq -er '.sdk' <<<"${tags}")
sdk_repository=ghcr.io/${owner}/"$(jq -er '.release.sdk_image' "${repository_root}/plugin-abi.lock")"
runtime_repository=ghcr.io/${owner}/$(
  "${repository_root}/scripts/plugin-abi.sh" render ci | jq -er '.runtime_image')
{
  printf 'plugin-sdk\t%s:%s\n' "${sdk_repository}" "${sdk_name#*:}"
  while IFS=$'\t' read -r host_id runtime_name; do
    printf 'runtime-%s\t%s:%s\n' "${host_id}" "${runtime_repository}" "${runtime_name#*:}"
  done < <(jq -r '.runtime | to_entries[] | [.key, .value] | @tsv' <<<"${tags}")
} >"${test_root}/publication.tsv"
canonical_tag_plan "${tags}" "${owner}" >"${test_root}/probe.tsv"
cmp -s "${test_root}/publication.tsv" "${test_root}/probe.tsv" ||
  die "the probe walks a different canonical set than publication writes:
$(paste -d'|' "${test_root}/publication.tsv" "${test_root}/probe.tsv" 2>/dev/null ||
  printf 'publication: %s\nprobe: %s\n' \
    "$(tr '\t' ' ' <"${test_root}/publication.tsv")" "$(tr '\t' ' ' <"${test_root}/probe.tsv")")"
# The recomputation above is only evidence if publication still builds its targets this way, so
# the shape is pinned in the source as well, following the same convention as
# tests/plugin-image-contract.sh. Without these the comparison would be a tautology: both sides
# would be my own function, and a change to publication's naming derivation would pass quietly.
publish=scripts/plugin-abi-publish.sh
grep -Fq 'sdk_canonical=${sdk_repository}:${sdk_name#*:}' "${publish}" ||
  die 'publication no longer derives the SDK canonical tag from the rendered name and owner'
grep -Fq 'runtime_canonical=${runtime_repository}:${runtime_name#*:}' "${publish}" ||
  die 'publication no longer derives runtime canonical tags from the rendered per-host name'
grep -Fq 'tags=$("${script_dir}/plugin-abi.sh" render tags)' "${publish}" ||
  die 'publication no longer takes its canonical names from render tags, so the candidate-mode
      render this probe walks would no longer be the same source of names'
grep -Fq 'owner=${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}' "${publish}" ||
  die 'publication no longer takes the registry owner from the repository context, which is the
      only reason the probe is allowed to derive namespaces the same way'

# A verdict is never taken without both identities it compares against, so a caller that loses one
# cannot default its way to allocatable.
if (canonical_tag_verdict absent '' "${this_abi}" '') >/dev/null 2>&1; then
  echo 'a missing predecessor identity was tolerated' >&2
  exit 1
fi

# The record's provenance field is asserted because a record citing the automatic merge ref names
# a commit that stops resolving once the pull request merges -- measured on PR #13, whose first
# artifact carried the merge ref rather than the head commit. The workflow supplies the head SHA for
# that reason, and the script rejects a malformed value before spending a registry pass on it.
probe_script=${repository_root}/scripts/probe-canonical-tags.sh
grep -Fq 'revision=${PLUGIN_ABI_PROBE_REVISION:-}' "${probe_script}" ||
  die 'the probe no longer prefers the workflow-supplied revision over GITHUB_SHA'
grep -Fq 'revision=${GITHUB_SHA:-not-in-ci}' "${probe_script}" ||
  die 'the probe no longer falls back to GITHUB_SHA outside a pull request'
grep -Fq 'must be a full lowercase commit SHA' "${probe_script}" ||
  die 'the probe no longer rejects a malformed revision'
check_line=$(grep -n 'must be a full lowercase commit SHA' "${probe_script}" | head -1 | cut -d: -f1)
walk_line=$(grep -n 'IFS=$'"'"'\\t'"'"' read -r probe_status held_by' "${probe_script}" | head -1 | cut -d: -f1)
((check_line < walk_line)) ||
  die "the revision is validated at line ${check_line}, after the registry walk at line ${walk_line}: a typo would cost a full probe pass to report"
grep -Fq 'PLUGIN_ABI_PROBE_REVISION: ${{ github.event.pull_request.head.sha }}' \
  "${repository_root}/.github/workflows/plugin-abi.yml" ||
  die 'the workflow no longer passes the head SHA, so records would cite an unresolvable merge ref'

echo 'Canonical tag allocatability classification passed: 7 verdicts, 5 probe states, 5 pairs, 1 plan equality, 1 provenance rule.'
