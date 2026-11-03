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

# A spent name can be accounted for by more than one earlier identity, and the single-slot form of
# this classifier could only ever account for one. Measured against the live registry: `v1.0.0-plugin`
# is held by the 2026-10-22 cast while `v1.0.0-ai-plugin` is held by a cast made under an identity
# function this lock no longer evaluates. Whichever one the slot records, the other comes back a
# collision, and a collision refuses the whole batch. Below, both are accounted at once.
predecessor_set=$(printf '%s\n%s\n' "${previous_abi}" "${other_abi}")
set_case() {
  local description=$1 held_by=$2 expected=$3 actual
  actual=$(canonical_tag_verdict occupied "${held_by}" "${this_abi}" "${predecessor_set}") ||
    die "${description}: set classification failed instead of answering"
  [[ ${actual} == "${expected}" ]] ||
    die "${description}: expected ${expected}, found ${actual}"
}
set_case 'accounted by the first predecessor' "${previous_abi}" superseded
set_case 'accounted by the second predecessor' "${other_abi}" superseded
# Membership is exact, so an identity that merely shares a prefix with a recorded predecessor is
# still unaccounted rather than absorbed into the set.
set_case 'a longer identity that starts like a predecessor' "${other_abi}ab" collision
# This lock's own identity outranks the set: the name is this contract's, so it is a republish and
# must not be softened into superseded, which would license skipping the artifact this lock owns.
set_case 'held by this contract while others are recorded' "${this_abi}" republish

# The set is read from two places, and an entry is legal only with a reason attached: a predecessor
# list nobody can justify is indistinguishable from a list written to make a gate pass.
history_lock=${test_root}/history.lock
history_file=${test_root}/history.json
jq -cn '{abi_id: "abi-1111111111111111111111111111111111111111111111111111111111111111",
        compatibility: {previous_sdk: {abi_id: "'${previous_abi}'"}}}' >"${history_lock}"
printf '{ "schema_version": 1, "predecessors": [] }\n' >"${history_file}"
[[ $(PLUGIN_ABI_HISTORY=${history_file} canonical_predecessor_abi_ids "${history_lock}") == \
  "${previous_abi}" ]] ||
  die 'an empty history must still yield the immediate predecessor on its own'

printf '{ "schema_version": 1, "predecessors": [ { "abi_id": "%s", "reason": "abandoned cast" } ] }\n' \
  "${other_abi}" >"${history_file}"
PLUGIN_ABI_HISTORY=${history_file} canonical_predecessor_abi_ids "${history_lock}" \
  >"${test_root}/set-read" || die 'reading a populated history failed'
[[ $(wc -l <"${test_root}/set-read") == 2 ]] ||
  die 'a populated history did not add its entry to the predecessor set'

# Rejected shapes. Each of these would otherwise degrade to "no extra predecessors" -- the silent
# direction, because it turns an accounted name back into a collision that refuses the batch.
history_case_rejected() {
  local description=$1 body=$2
  printf '%s\n' "${body}" >"${history_file}"
  # Subshelled because a rejection is signalled by `die`, which exits the whole script: without the
  # parentheses this could not observe the failure it is asserting.
  if (PLUGIN_ABI_HISTORY=${history_file} validate_publish_history "${history_lock}") \
    >"${test_root}/rejected" 2>&1; then
    echo "${description}: an invalid history was accepted" >&2
    exit 1
  fi
  grep -Fq 'invalid Plugin ABI publication history' "${test_root}/rejected" ||
    die "${description}: rejected for the wrong reason: $(tail -n 1 "${test_root}/rejected")"
}
history_case_rejected 'a predecessor with no reason' \
  '{ "schema_version": 1, "predecessors": [ { "abi_id": "'"${other_abi}"'" } ] }'
# A present but empty `reason` passes the shape check and can only be caught by the content check,
# so it is asserted separately: without this line the two guards are interchangeable and dropping
# either one looks safe.
history_case_rejected 'a predecessor whose reason is an empty string' \
  '{ "schema_version": 1, "predecessors": [ { "abi_id": "'"${other_abi}"'", "reason": "" } ] }'
history_case_rejected 'a predecessor duplicating another' \
  '{ "schema_version": 1, "predecessors": [ { "abi_id": "'"${other_abi}"'", "reason": "x" }, { "abi_id": "'"${other_abi}"'", "reason": "y" } ] }'
history_case_rejected 'a lock that supersedes itself' \
  '{ "schema_version": 1, "predecessors": [ { "abi_id": "abi-1111111111111111111111111111111111111111111111111111111111111111", "reason": "x" } ] }'
history_case_rejected 'a malformed identity' \
  '{ "schema_version": 1, "predecessors": [ { "abi_id": "abi-short", "reason": "x" } ] }'
history_case_rejected 'extra keys on an entry' \
  '{ "schema_version": 1, "predecessors": [ { "abi_id": "'"${other_abi}"'", "reason": "x", "note": "y" } ] }'
history_case_rejected 'a predecessors field that is not an array' \
  '{ "schema_version": 1, "predecessors": { "abi_id": "'"${other_abi}"'" } }'
history_case_rejected 'an unknown schema version' \
  '{ "schema_version": 2, "predecessors": [] }'

# The shipped history is read by publication and by the probe, so it is validated as shipped rather
# than only in fixtures: an entry added for convenience would otherwise reach a real gate untested.
validate_publish_history "${repository_root}/plugin-abi.lock" ||
  die 'the shipped plugin-abi-history.json does not validate against the shipped lock'

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

# The same transport read for a moving name, which additionally has to hand back the digest it read.
# The digest is the only part of an alias report that is not derivable from the lock, so a state
# reader that drops it leaves the reader with a name and no way to say what it serves.
alias_state_case() {
  local mock=$1 expected_status=$2 expected_holder=$3 expected_digest=$4 out status holder digest
  MOCK_PROBE=${mock}
  out=$(alias_reference_state ghcr.io/killbus/rulego-server:v1.0.0-plugin \
    2>"${test_root}/alias-${mock}.stderr") || die "${mock}: alias state read failed instead of answering"
  IFS=$'\t' read -r status holder digest <<<"${out}"
  [[ ${status} == "${expected_status}" ]] ||
    die "${mock}: alias expected status ${expected_status}, found ${status}"
  [[ ${holder} == "${expected_holder}" ]] ||
    die "${mock}: alias expected holder [${expected_holder}], found [${holder}]"
  [[ ${digest} == "${expected_digest}" ]] ||
    die "${mock}: alias expected digest [${expected_digest}], found [${digest}]"
}
alias_state_case free absent '' ''
alias_state_case occupied occupied "${previous_abi}" "sha256:${other_abi#abi-}"
alias_state_case unlabelled occupied unlabelled "sha256:${other_abi#abi-}"
# A name that resolves but whose index cannot be parsed is not an absent name, and must not be
# reported with a digest it never returned.
alias_state_case broken-index unreachable '' ''
alias_state_case transport-error unreachable '' ''

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

# The same states classified for a moving name, where none of them is a failure. `current` is the
# relation a canonical tag would call republish and a canonical gate would call nothing at all: for a
# pointer, holding this contract's identity means the promotion already happened.
relation_case() {
  local description=$1 status=$2 held=$3 predecessors_set=$4 expected=$5 actual
  actual=$(alias_reference_verdict "${status}" "${held}" "${this_abi}" "${predecessors_set}") ||
    die "${description}: alias classification failed instead of answering"
  [[ ${actual} == "${expected}" ]] ||
    die "${description}: expected ${expected}, found ${actual}"
}
relation_case 'a pointer not published yet' absent '' "${previous_abi}" absent
relation_case 'a pointer that could not be read' unreachable '' "${previous_abi}" unreachable
relation_case 'a pointer serving this contract' occupied "${this_abi}" "${previous_abi}" current
relation_case 'a pointer serving the recorded predecessor' occupied "${previous_abi}" "${previous_abi}" predecessor
# Membership in the accounted set, not only the immediate predecessor: two casts were measured in the
# live registry holding runtime names under two different identities.
relation_case 'a pointer serving an earlier cast in the history' occupied "${other_abi}" "${predecessor_set}" predecessor
relation_case 'a pointer serving an unexplained identity' occupied "${other_abi}" "${previous_abi}" unaccounted
# Generation-1 indexes carry no identity annotation. For a canonical tag that is a collision, because
# the batch cannot explain what it would overwrite. For a pointer it is unaccounted and harmless, and
# the annotation is reported rather than guessed at.
relation_case 'a pointer holding an unlabelled index' occupied unlabelled "${previous_abi}" unaccounted
relation_case 'a pointer holding a prefix of a predecessor' occupied "${other_abi}ab" "${predecessor_set}" unaccounted
if (alias_reference_verdict invented '' "${this_abi}" "${previous_abi}") >"${test_root}/alias-unknown" 2>&1; then
  echo 'an invented alias probe status was accepted' >&2
  exit 1
fi
grep -Fq 'unknown alias probe status' "${test_root}/alias-unknown"

# The plan the probe walks must be the set of names publication writes. Publication builds its
# canonical targets inline from the same rendered tags, the same owner and the same repository
# derivation; this asserts the derivation in `canonical_tag_plan` reproduces those exact strings,
# so neither side can drift into reporting on a name the other never touches.
# Publication renders its targets from the commit that produced the build, so this comparison has to
# render them from one too. The value is arbitrary here; what is being asserted is that the probe's
# derivation and publication's derivation produce the same strings from the same inputs.
name_revision=$(printf '2%.0s' {1..40})
export PLUGIN_ABI_NAME_REVISION="${name_revision}"
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
  done < <(jq -r '.runtime | to_entries[] | [.key, .value.canonical] | @tsv' <<<"${tags}")
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

# An alias is a moving name, so it must never reach the canonical plan: every consumer of a plan line
# treats it as a first-writer promise, and a promise on a name that is meant to move would block the
# next verified build from being promoted at all.
while IFS=$'\t' read -r _identity target; do
  while IFS=$'\t' read -r _host alias; do
    [[ ${target} != "ghcr.io/${owner}/${alias#*:}" ]] ||
      die "the canonical plan carries the moving alias ${target} as a first-writer promise"
  done < <(jq -r '.runtime | to_entries[] | [.key, .value.alias] | @tsv' <<<"${tags}")
done <"${test_root}/probe.tsv"
# Both tracks must still be present in the render, or the check above is comparing an empty set.
jq -e '.runtime | to_entries | (all(.value.canonical != null)) and (all(.value.alias != null))' \
  <<<"${tags}" >/dev/null || die 'the rendered tags lost one of the two name tracks'

# The moving names the probe reports are the moving names publication moves. Publication writes its
# record's `runtime_aliases` from `.runtime[].alias` prefixed by the repository it derived, so the
# derivation below is reproduced here and compared, and `scripts/promote-runtime-aliases.sh` compares
# the record against a re-render at runtime. Three checks on one rule is deliberate: the report is
# read by a person deciding whether to publish, and a report about a name publication never writes is
# worse than no report.
{
  while IFS=$'\t' read -r host_id alias_name; do
    printf 'runtime-%s\t%s:%s\n' "${host_id}" "${runtime_repository}" "${alias_name#*:}"
  done < <(jq -r '.runtime | to_entries[] | [.key, .value.alias] | @tsv' <<<"${tags}")
} >"${test_root}/publication-aliases.tsv"
alias_tag_plan "${tags}" "${owner}" >"${test_root}/probe-aliases.tsv"
cmp -s "${test_root}/publication-aliases.tsv" "${test_root}/probe-aliases.tsv" ||
  die "the probe reports a different set of moving names than publication moves:
publication: $(tr '\t' ' ' <"${test_root}/publication-aliases.tsv")
probe: $(tr '\t' ' ' <"${test_root}/probe-aliases.tsv")"
grep -Fq 'runtime_aliases=$(jq -c --arg repository "${runtime_repository}"' scripts/plugin-abi-publish.sh ||
  die 'publication no longer derives its recorded aliases from the rendered alias and the repository, so the comparison above would be a tautology'
# The alias plan is the canonical plan's complement, not a superset of it: no line may appear in both,
# and the SDK may appear in neither alias list, because a name that is its own identity has no pointer.
if comm -12 <(cut -f2 "${test_root}/probe.tsv" | sort) \
  <(cut -f2 "${test_root}/probe-aliases.tsv" | sort) | grep -q .; then
  echo 'a name appears in both the first-writer plan and the moving-name plan' >&2
  exit 1
fi
(( $(wc -l <"${test_root}/probe-aliases.tsv") == $(jq -r '.runtime | length' <<<"${tags}") )) ||
  die 'the moving-name plan does not cover exactly the locked hosts'
if grep -qF 'plugin-sdk' "${test_root}/probe-aliases.tsv"; then
  echo 'the moving-name plan carries an SDK name, which has no pointer to it' >&2
  exit 1
fi
# The probe must actually walk and record what it derives, or all of the above is a function nothing
# calls.
grep -Fq 'alias_plan=$(alias_tag_plan "${tags}" "${owner}")' scripts/probe-canonical-tags.sh ||
  die 'the probe no longer derives the moving names it claims to report'
grep -Fq 'aliases:$alias_results' scripts/probe-canonical-tags.sh ||
  die 'the probe reports moving names on stdout but leaves them out of the machine-readable record'
probe_src=scripts/probe-canonical-tags.sh
record_start=$(grep -n 'jq -cn --arg abi_id' "${probe_src}" | head -1 | cut -d: -f1)
[[ -n ${record_start} ]] || die 'the probe record program was not found to check its bindings'
record_end=$(grep -n '>"${record}"' "${probe_src}" | tail -1 | cut -d: -f1)
(( ${record_end} > ${record_start} )) ||
  die 'the probe record program has no closing write to check its bindings against'
record_program=$(sed -n "${record_start},${record_end}p" "${probe_src}")
# A field named in a jq program with no binding is a compile error on the path that writes the
# record, and that path needs a registry, so no offline case reaches it. Measured on this branch's
# first live probe run: the alias field was added to the program without its argjson binding, the
# canonical walk had already spent a full pass against GHCR, and the record was lost after a probe
# that printed as if it had passed. Shell variables here are written with braces and command
# substitutions start with a parenthesis, so a bare dollar-name in this region can only be a jq
# variable, and every one of them must have a binding.
jq_bound=$(printf '%s\n' "${record_program}" | grep -oE -- '--arg(json)? [a-z_]+' | awk '{print $2}' | sort -u)
jq_used=$(printf '%s\n' "${record_program}" | grep -oE '\$[a-z][a-z_0-9]*' | sed 's/^.//' | sort -u)
jq_unbound=$(comm -13 <(printf '%s\n' "${jq_bound}") <(printf '%s\n' "${jq_used}"))
[[ -z ${jq_unbound} ]] ||
  die "the probe record references jq variables with no binding: $(printf '%s ' ${jq_unbound})"
# And no alias state may ever join the list that reddens the job: a pointer is not a promise, and a red
# pull request because `v1.0.0-plugin` still serves last week's verified build is how a gate starts
# being ignored.
if grep -Eq 'red\+=\("?\$\{?alias' scripts/probe-canonical-tags.sh; then
  echo 'a moving-name state was made able to redden the allocatability probe' >&2
  exit 1
fi

# Publication may not render names in the pre-build mode: `none` makes every canonical runtime name
# null, and a plan with the hosts missing would approve a batch that no longer contains them.
grep -Fq 'export PLUGIN_ABI_NAME_REVISION=${packaging_revision}' "${publish}" ||
  die 'publication no longer names canonical runtime tags from the commit that built them'
grep -Fq 'require_canonical_plan_lines "${canonical_plan}"' "${publish}" ||
  die 'publication no longer counts the canonical plan against the lock, so a canonical runtime name
      that became null would silently shrink the batch instead of refusing the release'

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

# Same ordering rule for the publication history, asserted rather than trusted: dropping the call
# would silently degrade the accounted set to the lock's single predecessor, which is exactly the
# state that turns an explained name back into a batch-refusing collision.
grep -Fq 'validate_publish_history "${lock}"' "${probe_script}" ||
  die 'the probe no longer validates the publication history it is about to read'
history_line=$(grep -n 'validate_publish_history "${lock}"' "${probe_script}" | head -1 | cut -d: -f1)
((history_line < walk_line)) ||
  die "the publication history is validated at line ${history_line}, after the registry walk at line ${walk_line}: a malformed entry would cost a full probe pass to report"
read_line=$(grep -n 'predecessors=$(canonical_predecessor_abi_ids' "${probe_script}" | head -1 | cut -d: -f1)
((history_line < read_line)) ||
  die "the probe reads the predecessor set at line ${read_line} before validating it at line ${history_line}"
grep -Fq 'PLUGIN_ABI_PROBE_REVISION: ${{ github.event.pull_request.head.sha }}' \
  "${repository_root}/.github/workflows/plugin-abi.yml" ||
  die 'the workflow no longer passes the head SHA, so records would cite an unresolvable merge ref'

echo 'Canonical tag allocatability classification passed: 7 verdicts, 5 probe states, 5 pairs, 1 plan equality, 1 provenance rule, 4 set verdicts, 2 set reads, 8 rejected history shapes, 1 shipped history, 5 alias states, 8 alias relations, 1 alias plan equality, 3 alias plan rules, 3 alias probe wirings, 1 record binding check.'
