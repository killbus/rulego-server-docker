#!/usr/bin/env bash
# shellcheck disable=SC2016
# Two name tracks for runtime images: one name is won by a build and never moves, the other is the
# human-level name and moves only after verification.
#
# The rule this pins down is the one that decides whether a release can be made at all. A canonical
# name that does not change between builds is a name that has already been spent, and the gate would
# then refuse the release until the upstream version advanced. A canonical name that changes too
# freely, on the other hand, makes the immutable promise worth nothing. So the suffix is exactly the
# packaging commit -- not the lock digest, not the timestamp -- and the alias keeps the shape the
# published naming promise already describes.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${repository_root}/scripts/lib.sh"
# shellcheck source=tests/helpers.sh
source "${repository_root}/tests/helpers.sh"

mkdir -p "${repository_root}/tmp"
test_root=$(mktemp -d "${repository_root}/tmp/plugin-abi-runtime-naming.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

# Release-mode rendering refuses a lock that is still measuring, so the naming tests
# exercise the writing side against the shape a ready lock has.
ready_lock_file=${test_root}/ready.lock
ready_lock "${repository_root}/plugin-abi.lock" "${ready_lock_file}"
export PLUGIN_ABI_LOCK=${ready_lock_file}

rev_a=$(printf 'a%.0s' {1..40})
rev_b=$(printf 'b%.0s' {1..40})

render() {
  local revision=$1
  PLUGIN_ABI_NAME_REVISION=${revision} "${repository_root}/scripts/plugin-abi.sh" render tags --release
}

refusal() {
  local description=$1
  shift
  if ( "$@" ) >"${test_root}/refuse.out" 2>"${test_root}/refuse.err"; then
    printf 'expected a refusal: %s\n' "${description}" >&2
    cat "${test_root}/refuse.out" >&2
    exit 1
  fi
}

tags_a=$(render "${rev_a}")
tags_b=$(render "${rev_b}")
tags_none=$(render none)
recipe_tag=$(jq -er '.recipe_id | sub("^recipe-"; "") | .[0:12]' "${ready_lock_file}")

# Every host carries both tracks, and they are never the same string. A canonical name equal to its
# alias would put a moving name under the first-writer promise, so the next verified build could not
# be promoted at all.
while IFS=$'\t' read -r host_id canonical alias; do
  [[ ${canonical} != "${alias}" ]] || die "${host_id}: canonical and alias are the same name"
  [[ ${canonical} == "${alias}-r${recipe_tag}-${rev_a:0:12}" ]] ||
    die "${host_id}: canonical ${canonical} is not ${alias} plus the recipe and packaging revision"
  [[ ${alias} =~ ^rulego-server:v[0-9]+\.[0-9]+\.[0-9]+-[a-z0-9-]+$ ]] ||
    die "${host_id}: alias ${alias} left the published naming shape"
done < <(jq -r '.runtime | to_entries[] | [.key, .value.canonical, .value.alias] | @tsv' <<<"${tags_a}")

# A second build of this commit re-wins the same canonical name, which is what lets a rerun of an
# unchanged contract be recognised as its own content instead of a conflict.
rerun=$(render "${rev_a}")
while IFS=$'\t' read -r host_id first second; do
  [[ ${first} == "${second}" ]] ||
    die "${host_id}: the same packaging commit rendered two different canonical names"
done < <(join -t $'\t' \
  <(jq -r '.runtime | to_entries[] | [.key, .value.canonical] | @tsv' <<<"${tags_a}" | sort) \
  <(jq -r '.runtime | to_entries[] | [.key, .value.canonical] | @tsv' <<<"${rerun}" | sort))

# The next commit wins a different name, so an occupied name from an earlier generation cannot block
# this release. This is the property the whole change exists for.
canonical_a=$(jq -r '.runtime.plugin.canonical' <<<"${tags_a}")
canonical_b=$(jq -r '.runtime.plugin.canonical' <<<"${tags_b}")
alias_a=$(jq -r '.runtime.plugin.alias' <<<"${tags_a}")
alias_b=$(jq -r '.runtime.plugin.alias' <<<"${tags_b}")
[[ ${canonical_a} != "${canonical_b}" ]] ||
  die 'a new packaging commit won the same canonical runtime name'
[[ ${alias_a} == "${alias_b}" ]] || die 'the human-level alias moved between builds'

# The SDK is a compile input, so its name is the identity and nothing else. A build suffix there would
# mean two images with the same ABI face carry two names, and that a plugin could be pinned to a name
# whose bytes change under it.
sdk_a=$(jq -r '.sdk' <<<"${tags_a}")
sdk_b=$(jq -r '.sdk' <<<"${tags_b}")
sdk_none=$(jq -r '.sdk' <<<"${tags_none}")
[[ ${sdk_a} == "${sdk_b}" ]] || die 'the SDK canonical name depends on the packaging commit'
[[ $(jq -r '.sdk' <<<"${tags_a}") == *abi-* ]] || die 'the SDK canonical name does not name the identity'

# `none` is the pre-build state the probe renders in: the alias exists because the lock already
# determines it, and no canonical name exists because no build has decided one yet.
jq -e '.runtime | to_entries | (all(.value.canonical == null)) and (all(.value.alias != null))' \
  <<<"${tags_none}" >/dev/null ||
  die 'the pre-build render invented or lost a name track'
[[ ${sdk_none} == "${sdk_a}" ]] ||
  die 'the SDK name changed between the pre-build render and the build render'

# A partial revision is refused rather than shortened by guesswork: `deadbeef` is also somebody's
# branch name, and a canonical name minted from a value two callers derived differently would be won
# twice while looking immutable.
refusal 'render tags refuses a partial packaging revision' env PLUGIN_ABI_NAME_REVISION=deadbeef \
  "${repository_root}/scripts/plugin-abi.sh" render tags --release
refusal 'render tags refuses an absent packaging revision' env -u PLUGIN_ABI_NAME_REVISION \
  "${repository_root}/scripts/plugin-abi.sh" render tags --release
refusal 'render tags refuses a non-hex packaging revision' env PLUGIN_ABI_NAME_REVISION=zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz \
  "${repository_root}/scripts/plugin-abi.sh" render tags --release

# The plan the gate walks is a set of first-writer promises, so it carries every canonical name, the
# alias of no host, and nothing at all for a name no build has won yet.
host_count=$(jq -r '.distribution.hosts | length' "${ready_lock_file}")
plan_a=$(canonical_tag_plan "${tags_a}" killbus)
plan_none=$(canonical_tag_plan "${tags_none}" killbus)
plan_a_lines=$(wc -l <<<"${plan_a}" | tr -d ' ')
[[ ${plan_a_lines} == $((1 + host_count)) ]] ||
  die "the canonical plan has ${plan_a_lines} lines for ${host_count} hosts plus the SDK"
plan_none_lines=$(wc -l <<<"${plan_none}" | tr -d ' ')
[[ ${plan_none_lines} == 1 ]] ||
  die 'the pre-build plan promised a runtime name no build has won'
while IFS=$'\t' read -r _identity target; do
  if jq -e --arg target "${target}" '.runtime | to_entries | any(.value.alias == ($target | sub("^ghcr.io/killbus/"; "")))' \
    <<<"${tags_a}" >/dev/null; then
    die "the canonical plan carries the moving alias as a promise: ${target}"
  fi
done <<<"${plan_a}"

# The size check compares against the lock, so a plan that lost a host is refused instead of being
# read as a smaller batch that happens to be free.
printf 'plugin-sdk\tghcr.io/killbus/rulego-plugin-sdk:abi-x\n' >"${test_root}/one-line.tsv"
printf 'plugin-sdk\tghcr.io/killbus/rulego-plugin-sdk:abi-x\nruntime-plugin\tghcr.io/killbus/rulego-server:v1.0.0-plugin-aaaaaaaaaaaa\n' \
  >"${test_root}/two-line.tsv"
printf 'plugin-sdk\tghcr.io/killbus/rulego-plugin-sdk:abi-x\nruntime-plugin\tghcr.io/killbus/rulego-server:v1.0.0-plugin-aaaaaaaaaaaa\nruntime-ai-plugin\tghcr.io/killbus/rulego-server:v1.0.0-ai-plugin-aaaaaaaaaaaa\n' \
  >"${test_root}/three-line.tsv"
printf 'plugin-sdk\tghcr.io/killbus/rulego-plugin-sdk:abi-x\nruntime-plugin\tghcr.io/killbus/rulego-server:v1.0.0-plugin-aaaaaaaaaaaa\nruntime-ai-plugin\tghcr.io/killbus/rulego-server:v1.0.0-ai-plugin-aaaaaaaaaaaa\nruntime-all-plugin\tghcr.io/killbus/rulego-server:v1.0.0-all-plugin-aaaaaaaaaaaa\n' \
  >"${test_root}/four-line.tsv"
require_canonical_plan_lines "${test_root}/four-line.tsv" 3
refusal 'a plan missing a host is refused' require_canonical_plan_lines "${test_root}/three-line.tsv" 3
refusal 'a plan with an extra line is refused' require_canonical_plan_lines "${test_root}/four-line.tsv" 2

# Publication still renders its own names and still exports the identity it renders them from, so the
# plan the probe walks and the plan the gate reads cannot drift into naming different objects.
publish=scripts/plugin-abi-publish.sh
grep -Fq 'export PLUGIN_ABI_NAME_REVISION=${packaging_revision}' "${publish}" ||
  die 'publication no longer names canonical runtime tags from the commit that built them'
plan_guard='publication no longer counts the canonical plan against the lock: a canonical runtime'
plan_guard+='name that came out null would shrink the batch instead of refusing the release'
grep -Fq 'require_canonical_plan_lines "${canonical_plan}"' "${publish}" || die "${plan_guard}" 
grep -Fq 'tags=$("${script_dir}/plugin-abi.sh" render tags)' "${publish}" ||
  die 'publication no longer takes its names from render tags'
# Publication may not render in the pre-build mode. `none` is legal in the renderer because the probe
# needs it, so the refusal has to live on the writing side: the packaging revision is checked to be a
# full commit *before* it is exported for the render, which is the order that makes `none` unreachable
# here. Asserting the order rather than a message keeps this honest if the wording changes.
revision_guard=$(grep -n 'GITHUB_SHA must be a full lowercase commit revision' "${publish}" | cut -d: -f1)
name_export=$(grep -n 'export PLUGIN_ABI_NAME_REVISION' "${publish}" | cut -d: -f1)
[[ -n ${revision_guard} && -n ${name_export} ]] ||
  die 'publication neither validates the packaging revision nor exports it for the name render'
((revision_guard < name_export)) ||
  die 'publication renders canonical runtime names before the packaging revision is validated'

probe=scripts/probe-canonical-tags.sh
grep -Fq 'PLUGIN_ABI_NAME_REVISION=none' "${probe}" ||
  die 'the probe no longer renders the pre-build name track, so it would ask about names no build won'
grep -Fq 'PLUGIN_ABI_NAME_REVISION=${revision}' "${probe}" ||
  die 'the probe no longer renders canonical names from the commit it stands for'

echo 'Runtime naming keeps one immutable name per build and one verified alias per host'
