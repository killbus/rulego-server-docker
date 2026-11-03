#!/usr/bin/env bash
# Probe whether each canonical tag of the current lock is allocatable, writing nothing.
#
# The pipeline asks this question for real only inside `require_immutable_tags_publishable`, the
# last gate before the first write, and it answers for the whole plan at once: one occupied tag
# refuses every tag in the batch, so a variant whose own name is free still cannot be released and
# the rejection names no variant. That gate keeps its authority and is unchanged. What it cannot
# do is tell anyone, before a release is already blocked, which name is the blocker or whether the
# rest of the batch was fine. This probe asks the same question one canonical target at a time and
# without a build, so a change that makes a name unallocatable is visible on the pull request that
# introduces it rather than at the publish that needs it.
#
# Scope, stated so it is not mistaken for more than it is: a canonical tag whose content has not
# been built cannot be compared by digest, so nothing here proves anything about content. It proves
# which names are free, which already hold this contract, and which hold the contract this lock
# replaced. The write-before gate remains the only authority on content.
#
# A name held by the superseded contract is reported and not failed. That is not leniency: runtime
# canonical tags are named after the upstream release, so once an earlier contract claimed
# `v1.0.0-plugin` no later lock can, and a gate that reddened on that would be permanently red on
# main -- the exact condition under which checks get weakened until they mean nothing. The
# blocker is instead named, in a machine-readable record, so the operator sees which host is
# blocked and which are not. The comparison is data, not recall: publication writes
# `io.rulego.abi.id` into every canonical index, and the identity it names is read from the lock
# rather than retyped.
#
# The moving names are read along with the canonical ones and never judged. A pointer holding an
# earlier verified build is the ordinary state of a pointer, and the question a reader asks about it
# -- which bytes does the public name serve today -- has no other answer in this repository before a
# release runs. Reporting it on the pull request is what makes the gap between a public name and a
# verified build visible at the moment the change that widens it is merged.
#
# One recorded predecessor is not always enough. Measured after the first real publication, two
# runtime names were spent by two different identities -- the contract this lock replaced, and an
# earlier cast made under an identity function this lock no longer evaluates -- and a single slot
# can vouch for only one of them, which leaves the other reading as a collision and refuses a batch
# whose own names are all free. So the accounted set is the lock's immediate predecessor plus the
# casts recorded in `plugin-abi-history.json`. That file lives outside the lock on purpose: the lock
# is canonicalized into the manifest copied into both images, so recording history inside it would
# change every published digest without changing one compiled byte. Each entry carries a reason,
# because a predecessor list nobody can justify is indistinguishable from one written to pass a
# gate. Anything held by an identity outside the set is unexplained and fails; a registry that
# cannot answer is never counted as free.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

# `lib.sh` does not define the lock path, so it is resolved the same way `plugin-abi.sh` resolves
# it. Reading a different file than the renders below report on would make the predecessor
# comparison, and therefore the whole verdict, evidence about some other lock.
lock=${PLUGIN_ABI_LOCK:-${repository_root}/plugin-abi.lock}

record=''
revision=${PLUGIN_ABI_PROBE_REVISION:-}
[[ -n ${revision} ]] || revision=${GITHUB_SHA:-not-in-ci}
case ${1:-} in
  '') ;;
  --record)
    [[ $# == 2 ]] || die 'usage: scripts/probe-canonical-tags.sh [--record <path>]'
    record=$2
    ;;
  *) die 'usage: scripts/probe-canonical-tags.sh [--record <path>]' ;;
esac

# Checked before anything runs, not when the record is written: a malformed revision should not
# cost a full pass against the registry before it says so.
[[ ${revision} == not-in-ci || ${revision} =~ ^[0-9a-f]{40}$ ]] ||
  die "probe revision must be a full lowercase commit SHA, found: ${revision}"

# Candidate validation on purpose: a name is worth probing while the contract is still measuring,
# which is exactly when nothing is publishable. Asking in release mode would refuse to run until
# after the decision this probe informs. Publication still renders tags in release mode.
"${script_dir}/plugin-abi.sh" validate --candidate
abi_id=$("${script_dir}/plugin-abi.sh" render id)
lock_digest=$("${script_dir}/plugin-abi.sh" render lock-digest)
# Validated before the registry walk for the same reason the revision is: a history file with a
# typo would otherwise cost a full pass to report, and a reader could not tell a malformed entry
# apart from an empty set. An empty set is a legal state; an unreadable one is not.
validate_publish_history "${lock}"
predecessors=$(canonical_predecessor_abi_ids "${lock}")
# The canonical runtime name is won by a build, so the probe renders it from the revision this run
# stands for: a pull-request run asks about the name that pull request's commit would win, and a run
# with no commit at all (`not-in-ci`, which is a local run) asks only about the names the lock already
# determines by itself. That is a narrower question, so the narrower answer is reported below rather
# than passed off as the whole batch having been checked.
if [[ ${revision} == not-in-ci ]]; then
  export PLUGIN_ABI_NAME_REVISION=none
else
  export PLUGIN_ABI_NAME_REVISION=${revision}
fi
tags=$("${script_dir}/plugin-abi.sh" render tags --candidate)

# The owner comes from the repository context because that is where publication takes it. A probe
# that derived its namespace elsewhere would report on tags nothing writes to, and a green result
# would then be evidence about the wrong repository.
owner=${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}
owner=${owner,,}

# The same derivation publication's targets come from, so the probe cannot report on a name
# nothing writes to.
plan=$(canonical_tag_plan "${tags}" "${owner}")

results='[]'
collisions=0
unreachable=0
superseded=0
republish=0
# Stated up front, because the answer is narrower than the batch when no build identity exists: the
# SDK name is decided by the lock and is always asked about, while a canonical runtime name is decided
# by a build and cannot be named before one. Silently probing one name and reporting a pass would make
# a local run look like evidence about names nothing has chosen yet.
if [[ ${PLUGIN_ABI_NAME_REVISION} == none ]]; then
  log 'no build identity is available, so the per-build canonical runtime names are not probed; the'
  log 'SDK canonical name is still probed and the moving names are still read below'
fi
while IFS=$'\t' read -r identity target; do
  [[ -n ${identity} && -n ${target} ]] || die "invalid canonical target plan line for ${identity}"
  probe_status=''
  held_by=''
  # The probe answers `<status>\t<held-by>` on exactly one line, split with the same
  # tab-delimited read the rest of the pipeline uses rather than by pattern-matching on an
  # invisible literal tab. A read that does not succeed means the probe was prevented from
  # answering, which is a red and never a silent allocatable.
  IFS=$'\t' read -r probe_status held_by < <(canonical_tag_probe "${target}") ||
    die "canonical tag probe returned no verdict for ${target}"
  verdict=$(canonical_tag_verdict "${probe_status}" "${held_by}" "${abi_id}" "${predecessors}")
  printf '%-18s %-12s %s\n' "${identity}" "${verdict}" "${target}"
  case ${verdict} in
    collision) collisions=$((collisions + 1)) ;;
    unreachable) unreachable=$((unreachable + 1)) ;;
    superseded) superseded=$((superseded + 1)) ;;
    republish) republish=$((republish + 1)) ;;
  esac
    results=$(jq -c --arg identity "${identity}" --arg target "${target}" \
    --arg probe_status "${probe_status}" --arg held_by "${held_by}" --arg verdict "${verdict}" \
    '. += [{identity:$identity,target:$target,probe_status:$probe_status,
            held_by_abi_id:(if $held_by=="" then null else $held_by end),verdict:$verdict}]' \
    <<<"${results}")
done <<<"${plan}"

# The moving names, read but never judged.
#
# An alias is not part of the allocatability question above: it is a pointer, first-writer does not
# apply to it, and nothing about this release can be blocked by what it currently serves. What a
# reader wants to know is what `v1.0.0-plugin` resolves to today and whether that content belongs to
# this contract, an accounted predecessor, or nobody -- the last of which is a fact no other check
# states, because a pointer holding an unexplained identity is legal and passes. The names come from
# `alias_tag_plan`, derived alongside the canonical plan so the report cannot describe a set of names
# different from the set publication moves.
alias_plan=$(alias_tag_plan "${tags}" "${owner}")
alias_results='[]'
alias_unaccounted=0
alias_absent=0
alias_unreachable=0
while IFS=$'\t' read -r identity target; do
  [[ -n ${identity} && -n ${target} ]] || die "invalid alias plan line for ${identity}"
  IFS=$'\t' read -r alias_status alias_held alias_digest < <(alias_reference_state "${target}") ||
    die "alias probe returned no verdict for ${target}"
  relation=$(alias_reference_verdict "${alias_status}" "${alias_held}" "${abi_id}" "${predecessors}")
  printf '%-18s %-12s %s %s\n' "${identity}" "alias:${relation}" "${target}" "${alias_digest:--}"
  case ${relation} in
    unaccounted) alias_unaccounted=$((alias_unaccounted + 1)) ;;
    absent) alias_absent=$((alias_absent + 1)) ;;
    unreachable) alias_unreachable=$((alias_unreachable + 1)) ;;
  esac
  alias_results=$(jq -c --arg identity "${identity}" --arg target "${target}" \
    --arg probe_status "${alias_status}" --arg held_by "${alias_held}" --arg digest "${alias_digest}" \
    --arg relation "${relation}" \
    '. += [{identity:$identity,target:$target,probe_status:$probe_status,
            held_by_abi_id:(if $held_by=="" then null else $held_by end),
            digest:(if $digest=="" then null else $digest end),relation:$relation}]' \
    <<<"${alias_results}")
done <<<"${alias_plan}"

if [[ -n ${record} ]]; then
  mkdir -p -- "$(dirname -- "${record}")"
  # The revision comes from a workflow input rather than GITHUB_SHA, because under a pull_request
  # event GITHUB_SHA is the SHA of the automatic merge ref. That object is what the job actually
  # builds, but it lives on no branch and stops resolving once the pull request merges, so a record
  # naming it cites a commit nobody can look up afterwards. The head SHA is the durable, reviewable
  # object. Measured on PR #13, whose first record carried the merge ref. `not-in-ci` is permitted
  # only when neither source exists, and is rejected as a value rather than guessed at.
  jq -cn --arg abi_id "${abi_id}" --arg lock_digest "${lock_digest}" \
    --arg previous_abi_id "$(jq -er '.compatibility.previous_sdk.abi_id' "${lock}")" \
    --arg revision "${revision}" --arg name_revision "${PLUGIN_ABI_NAME_REVISION}" \
    --argjson results "${results}" \
    --argjson alias_results "${alias_results}" \
    --argjson predecessors "$(printf '%s\n' "${predecessors}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    '{abi_id:$abi_id,lock_digest:$lock_digest,previous_abi_id:$previous_abi_id,
      predecessor_abi_ids:$predecessors,
      probe_revision:$revision,name_revision:$name_revision,targets:$results,
      aliases:$alias_results}' >"${record}"
fi

# Counted separately because the two send the reader to different places: an unaccounted holder is
# a contract fact to fix, and a registry that could not answer is an environment property -- this
# job runs anonymously against GHCR, so a rate limit or an outage must not be reported as if a name
# were taken. Both are red, and neither is allowed to be read as the other.
red=()
((collisions == 0)) ||
  red+=("${collisions} canonical tag(s) held by an identity this lock does not account for")
((unreachable == 0)) ||
  red+=("${unreachable} canonical tag(s) could not be probed, which is not the same as allocatable")
((${#red[@]} == 0)) || die "$(printf '%s; ' "${red[@]}")"
((republish == 0)) ||
  log "${republish} canonical tag(s) already carry this contract's identity; publication writes nothing for them only when this build's bytes equal the bytes already published under those names, and this job builds nothing, so it reports the state instead of calling it free"
((superseded == 0)) ||
  log "${superseded} canonical tag(s) are held by an accounted predecessor ($(printf '%s\n' "${predecessors}" | paste -sd' ' -)); publication leaves those hosts alone and their names keep resolving to the bytes that predecessor published, so nothing else in this batch is blocked by them"
# Reported and never required. The three states say different things about the public name, and none
# of them says anything about whether this release may proceed: `current` means the pointer already
# follows this contract, `absent` means nothing has published it yet, `unaccounted` means it serves an
# identity no record explains. That last one is the reason this section exists -- it is legal, it
# blocks nothing, and before this report nothing in the pipeline ever said it out loud.
((alias_unaccounted == 0)) ||
  log "${alias_unaccounted} moving name(s) serve an identity neither this lock nor the publication history accounts for; promotion is what changes that, and this release is not blocked by it"
((alias_absent == 0)) ||
  log "${alias_absent} moving name(s) are not published yet; the first verified promotion of this release line creates them"
((alias_unreachable == 0)) ||
  log "${alias_unreachable} moving name(s) could not be read; unlike a canonical name, an unread alias changes nothing about this release, because a pointer is not a first-writer promise"
log "canonical tag allocatability probe passed for ${abi_id}"
