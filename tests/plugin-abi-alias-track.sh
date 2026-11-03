#!/usr/bin/env bash
# shellcheck disable=SC2016
# Offline guards for scripts/promote-runtime-aliases.sh, the step that moves the human-level names.
#
# Three things have to hold at once here, and each is a way this step could be worse than the old
# unconditional write. The names it moves must be the names the naming function produces, so a release
# record that drifted from the code cannot publish a name the contract no longer describes. The move
# must be licensed by content a verifier confirmed, so a record whose digest is not what the canonical
# tag actually holds has to stop. And every move that did happen must survive in an undo record,
# including the ones that succeeded before a later host failed -- that is exactly when the record is
# needed. All three are asserted against a registry stub, because a live registry cannot be asked to
# hold one specific digest on demand.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${repository_root}/scripts/lib.sh"

mkdir -p "${repository_root}/tmp"
test_root=$(mktemp -d "${repository_root}/tmp/plugin-abi-alias-track.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT
registry_dir=${test_root}/registry
log_file=${test_root}/docker.log
move_dir=${test_root}/alias-moves
record_path=${test_root}/plugin-abi-release.json

mkdir -p "${test_root}/bin" "${registry_dir}" "${move_dir}"

image=ghcr.io/example/rulego-server
verified_digest=sha256:$(printf 'a%.0s' {1..64})
drifted_digest=sha256:$(printf 'b%.0s' {1..64})
prior_digest=sha256:$(printf 'c%.0s' {1..64})
mismatch_digest=sha256:$(printf 'e%.0s' {1..64})
revision=$(printf 'd%.0s' {1..40})

DOCKER_MOCK_DIR=${registry_dir}
DOCKER_MOCK_LOG=${log_file}
export DOCKER_MOCK_DIR DOCKER_MOCK_LOG

# Same stub as tests/alias-promotion.sh: references resolve through a file of index JSON, a write
# stores what the registry now holds for that tag, and MOCK_WRONG_DIGEST makes one name answer
# differently from what was written. That knob models a registry disagreeing with the release record.
cat >"${test_root}/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%q ' "$@" >>"${DOCKER_MOCK_LOG}"
printf '\n' >>"${DOCKER_MOCK_LOG}"

path_for() {
  printf '%s/%s' "${DOCKER_MOCK_DIR}" "$(printf '%s' "${1##*/}" | tr ':@' '__')"
}

if [[ $1 == buildx && $2 == imagetools && $3 == inspect ]]; then
  file=$(path_for "$4")
  [[ -f ${file} ]] || { printf 'errors:\n  - errors:\n    - manifest unknown\n' >&2; exit 1; }
  if [[ -n ${MOCK_WRONG_DIGEST:-} && $4 == *"${MOCK_WRONG_DIGEST}" ]]; then
    jq --arg digest "${MOCK_MISMATCH_DIGEST}" '.digest = $digest' "${file}"
    exit 0
  fi
  cat "${file}"
  exit 0
fi

if [[ $1 == buildx && $2 == imagetools && $3 == create ]]; then
  tag=''
  source=''
  while (($#)); do
    if [[ $1 == --tag ]]; then tag=$2; shift 2; continue; fi
    source=$1
    shift
  done
  [[ -n ${tag} && -n ${source} ]] || { printf 'mock create needs a tag and a source\n' >&2; exit 64; }
  # A source that is not digest-addressed is a caller bug: promoting by tag name would let the alias
  # follow the canonical tag the next time it moves, so the mock refuses to hide it.
  [[ ${source} == *@sha256:* ]] || { printf 'mock create refused: source is not digest-addressed\n' >&2; exit 64; }
  digest=${source##*@}
  if [[ -n ${MOCK_WRONG_WRITE:-} && ${tag} == *"${MOCK_WRONG_WRITE}" ]]; then
    digest=${MOCK_MISMATCH_DIGEST}
  fi
  jq -n --arg digest "${digest}" '{
    mediaType: "application/vnd.oci.image.index.v1+json",
    digest: $digest,
    manifests: [
      {digest: $digest, platform: {os: "linux", architecture: "amd64"}},
      {digest: $digest, platform: {os: "linux", architecture: "arm64"}}
    ]
  }' >"$(path_for "${tag}")"
  exit 0
fi

printf 'unexpected docker invocation:' >&2
printf ' %q' "$@" >&2
printf '\n' >&2
exit 64
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"${test_root}/bin/sleep"
chmod +x "${test_root}/bin/docker" "${test_root}/bin/sleep"

registry_path() {
  printf '%s/%s' "${registry_dir}" "$(printf '%s' "${1##*/}" | tr ':@' '__')"
}

put_index() {
  local reference=$1 digest=$2
  jq -n --arg digest "${digest}" '{
    mediaType: "application/vnd.oci.image.index.v1+json",
    digest: $digest,
    manifests: [
      {digest: $digest, platform: {os: "linux", architecture: "amd64"}},
      {digest: $digest, platform: {os: "linux", architecture: "arm64"}}
    ]
  }' >"$(registry_path "${reference}")"
}

wipe_registry() {
  rm -rf -- "${registry_dir}" "${move_dir}"
  mkdir -p "${registry_dir}" "${move_dir}"
  : >"${log_file}"
}

# Names come from the real naming function and the real lock, so the record under test is shaped like
# the one scripts/plugin-abi-publish.sh writes. A fixture that hard-coded its own tags would keep
# passing even if the wrapper and the render disagreed, and that disagreement is the thing this step
# exists to catch.
tags=$(PLUGIN_ABI_NAME_REVISION=${revision} "${repository_root}/scripts/plugin-abi.sh" render tags --release)
mapfile -t hosts < <(jq -r '.runtime | keys_unsorted | sort | .[]' <<<"${tags}")
(( ${#hosts[@]} == 2 )) || die "this suite needs the locked host set to have two entries, found ${#hosts[@]}"
first=${hosts[0]}
second=${hosts[1]}
first_alias_tag=$(jq -er --arg h "${first}" '.runtime[$h].alias | split(":")[1]' <<<"${tags}")
second_alias_tag=$(jq -er --arg h "${second}" '.runtime[$h].alias | split(":")[1]' <<<"${tags}")
first_canonical=${image}:$(jq -er --arg h "${first}" '.runtime[$h].canonical | split(":")[1]' <<<"${tags}")
second_canonical=${image}:$(jq -er --arg h "${second}" '.runtime[$h].canonical | split(":")[1]' <<<"${tags}")
first_alias=${image}:${first_alias_tag}
second_alias=${image}:${second_alias_tag}
[[ ${first_canonical} != "${first_alias}" ]] || die 'the fixture cannot tell the two tracks apart'

# make_record <packaging-revision> <runtime object> <alias object> <superseded array>
make_record() {
  local rev=$1 runtime=$2 aliases=$3 superseded=$4
  jq -S -n --arg rev "${rev}" --arg abi abi-fixturetest00000000000000000000000000000000000000000000000000000 \
    --arg sdk "${image}-sdk:abi-fixture" --arg lock "sha256:$(printf '0%.0s' {1..64})" \
    --argjson runtime "${runtime}" --argjson aliases "${aliases}" --argjson superseded "${superseded}" \
    '{abi_id:$abi,lock_digest:$lock,packaging_revision:$rev,sdk:$sdk,
      runtime:$runtime,runtime_aliases:$aliases,superseded_hosts:$superseded}' >"${record_path}"
}

runtime_one=$(jq -n --arg h "${first}" --arg r "${image}@${verified_digest}" '{$h: $r}')
aliases_one=$(jq -n --arg h "${first}" --arg a "${image}:${first_alias_tag}" '{$h: $a}')
runtime_both=$(jq -n --arg h1 "${first}" --arg r1 "${image}@${verified_digest}" \
  --arg h2 "${second}" --arg r2 "${image}@${verified_digest}" '{$h1: $r1, $h2: $r2}')
aliases_both=$(jq -n --arg h1 "${first}" --arg a1 "${image}:${first_alias_tag}" \
  --arg h2 "${second}" --arg a2 "${image}:${second_alias_tag}" '{$h1: $a1, $h2: $a2}')

run_promote() {
  local expected=$1 record=${2:-"${record_path}"}
  local status=0
  set +e
  env PATH="${test_root}/bin:${PATH}" \
    TMPDIR=/tmp \
    PROMOTE_ALIAS_RECORD_DIR="${move_dir}" \
    DOCKER_MOCK_DIR="${registry_dir}" \
    DOCKER_MOCK_LOG="${log_file}" \
    MOCK_WRONG_DIGEST="${MOCK_WRONG_DIGEST:-}" \
    MOCK_WRONG_WRITE="${MOCK_WRONG_WRITE:-}" \
    MOCK_MISMATCH_DIGEST="${mismatch_digest}" \
    REGISTRY_RETRY_ATTEMPTS=2 REGISTRY_RETRY_INITIAL_DELAY=1 REGISTRY_RETRY_MAX_DELAY=1 \
    bash "${repository_root}/scripts/promote-runtime-aliases.sh" "${record}" \
    >"${test_root}/stdout" 2>"${test_root}/stderr"
  status=$?
  set -e
  if [[ -z ${expected} ]]; then
    ((status == 0)) || {
      printf 'expected success, got exit %s\n' "${status}" >&2
      cat "${test_root}/stderr" >&2
      exit 1
    }
    return
  fi
  ((status != 0)) || {
    printf 'expected failure containing: %s\n' "${expected}" >&2
    cat "${test_root}/stdout" "${test_root}/stderr" >&2
    exit 1
  }
  grep -q -- "${expected}" "${test_root}/stderr" || {
    printf 'the failure said something else than: %s\n' "${expected}" >&2
    cat "${test_root}/stderr" >&2
    exit 1
  }
}

wrote_anything() {
  grep -q -- 'imagetools create' "${log_file}"
}

# A record that addresses no runtime: the release published its SDK and left every runtime name to an
# accounted predecessor, so there is no digest to move an alias onto. Exiting 0 with a message is the
# honest answer. Exiting 1 would make a legal release look failed; exiting silently would let the
# public name keep pointing at content this contract replaced without anything recording that.
wipe_registry
make_record "${revision}" '{}' '{}' '[]'
run_promote ''
if wrote_anything; then
  echo 'an empty runtime set must not write to the registry' >&2
  exit 1
fi
grep -qi 'no runtime image' "${test_root}/stderr" || {
  echo 'an empty runtime set must say so rather than exit silently' >&2
  cat "${test_root}/stderr" >&2
  exit 1
}

# Happy path, one host: the alias is repointed at the digest the record holds, addressed by digest
# rather than by the canonical tag, so the alias does not silently follow the canonical name later.
wipe_registry
put_index "${first_canonical}" "${verified_digest}"
put_index "${first_alias}" "${prior_digest}"
make_record "${revision}" "${runtime_one}" "${aliases_one}" '[]'
run_promote ''
grep -q -- "--tag ${first_alias} ${image}@${verified_digest}" "${log_file}" \
  || { echo 'the alias must be pointed at the verified digest, not at the canonical tag' >&2; exit 1; }
grep -q -- "\"digest\": \"${verified_digest}\"" "$(registry_path "${first_alias}")" \
  || { echo 'the alias did not end up at the verified digest' >&2; exit 1; }

# The undo record has to name where the alias used to point, or a bad promotion is repaired from
# memory. The checks are on the tags the naming function produced, not on today's literal strings.
move_record=${move_dir}/alias-move-${first}.json
[[ -f ${move_record} ]] || { echo 'the promotion left no undo record' >&2; exit 1; }
jq -e --arg alias "${first_alias}" --arg from "${prior_digest}" --arg to "${verified_digest}" '
  .canonical_digest == $to and
  (.moves | length) == 1 and
  (.moves[0] | .alias == $alias and .from == $from and .to == $to)
' "${move_record}" >/dev/null || {
  printf 'unexpected undo record: %s\n' "$(<"${move_record}")" >&2
  exit 1
}

# Both hosts published: two moves and two undo records. This is the case a single shared record path
# loses, because the second promotion opens the same file and truncates the first move out of it.
wipe_registry
put_index "${first_canonical}" "${verified_digest}"
put_index "${second_canonical}" "${verified_digest}"
put_index "${first_alias}" "${prior_digest}"
put_index "${second_alias}" "${prior_digest}"
make_record "${revision}" "${runtime_both}" "${aliases_both}" '[]'
run_promote ''
for host_id in "${first}" "${second}"; do
  [[ -f "${move_dir}/alias-move-${host_id}.json" ]] || {
    printf 'no undo record for %s after a two-host promotion\n' "${host_id}" >&2
    ls -1 "${move_dir}" >&2
    exit 1
  }
done
# Each record describes its own host: two files that both recorded the first move would undo one
# alias and leave the other pointing wherever it was last pointed without anything saying so.
jq -e --arg alias "${first_alias}" --arg from "${prior_digest}" --arg to "${verified_digest}" \
  '(.moves | length) == 1 and (.moves[0] | .alias == $alias and .from == $from and .to == $to)' \
  "${move_dir}/alias-move-${first}.json" >/dev/null || {
  printf 'unexpected undo record for %s: %s\n' "${first}" "$(<"${move_dir}/alias-move-${first}.json")" >&2
  exit 1
}
jq -e --arg alias "${second_alias}" --arg from "${prior_digest}" --arg to "${verified_digest}" \
  '(.moves | length) == 1 and (.moves[0] | .alias == $alias and .from == $from and .to == $to)' \
  "${move_dir}/alias-move-${second}.json" >/dev/null || {
  printf 'unexpected undo record for %s: %s\n' "${second}" "$(<"${move_dir}/alias-move-${second}.json")" >&2
  exit 1
}
(( $(grep -c -- 'imagetools create' "${log_file}") == 2 )) \
  || { echo 'a two-host promotion must move both aliases and nothing else' >&2; exit 1; }

# The second host's alias does not land where it was pointed. The first move is real and already
# public, so it must stay undoable: this run fails, and the first record has to survive it. The knob is
# matched on the full reference because the alias is a prefix of the canonical name: `v1.0.0-plugin`
# is held inside `v1.0.0-plugin-<revision>`, so a short suffix would also catch the canonical probe.
wipe_registry
put_index "${first_canonical}" "${verified_digest}"
put_index "${second_canonical}" "${verified_digest}"
put_index "${first_alias}" "${prior_digest}"
MOCK_WRONG_DIGEST=${second_alias}
make_record "${revision}" "${runtime_both}" "${aliases_both}" '[]'
run_promote 'after promotion, expected'
MOCK_WRONG_DIGEST=''
jq -e --arg alias "${first_alias}" --arg to "${verified_digest}" \
  '(.moves | length) == 1 and (.moves[0] | .alias == $alias and .to == $to)' \
  "${move_dir}/alias-move-${first}.json" >/dev/null || {
  printf 'the successful move lost its record when a later host failed: %s\n' \
    "$(<"${move_dir}/alias-move-${first}.json")" >&2
  exit 1
}

# A record that lists a host as superseded and also holds a digest for it is a contradiction, and the
# superseded entry is the one the gate wrote. Promoting from it would point a public name at bytes this
# build never wrote, which is the exact failure the verify-then-move ordering exists to prevent.
wipe_registry
put_index "${first_canonical}" "${verified_digest}"
superseded_first=$(jq -n --arg host "${first}" '[$host]')
make_record "${revision}" "${runtime_one}" "${aliases_one}" "${superseded_first}"
run_promote 'recorded as superseded'
if wrote_anything; then
  echo 'a superseded host must not have its alias promoted' >&2
  exit 1
fi

# The record names an alias the naming function no longer produces. Refusing here is what keeps two
# copies of the naming rule from disagreeing in silence: the wrapper trusts neither the record alone nor
# a name it rebuilt alone, it compares the two.
wipe_registry
put_index "${first_canonical}" "${verified_digest}"
put_index "${first_alias}" "${prior_digest}"
drifted_aliases=$(jq -n --arg host "${first}" --arg ref "${image}:${first_alias_tag}-renamed" '{$host: $ref}')
make_record "${revision}" "${runtime_one}" "${drifted_aliases}" '[]'
run_promote 'the naming function says'
if wrote_anything; then
  echo 'a record whose alias drifted from the naming function must write nothing' >&2
  exit 1
fi

# The canonical tag no longer holds what the record says it published. The licence to move comes from
# content a verifier confirmed, so the drift stops the promotion inside promote-alias.sh and the public
# name keeps the digest it had.
wipe_registry
put_index "${first_canonical}" "${drifted_digest}"
put_index "${first_alias}" "${prior_digest}"
make_record "${revision}" "${runtime_one}" "${aliases_one}" '[]'
run_promote 'refusing to promote any alias'
if wrote_anything; then
  echo 'a drifted canonical tag must not license an alias move' >&2
  exit 1
fi
grep -q -- "\"digest\": \"${prior_digest}\"" "$(registry_path "${first_alias}")" \
  || { echo 'the refused alias must keep its previous digest' >&2; exit 1; }

# A runtime value that is a tag rather than a digest address cannot license anything. Read by the same
# split as a real record it looks like a repository, and the alias would move to whatever that name
# happens to resolve to at the moment of the write.
wipe_registry
put_index "${first_canonical}" "${verified_digest}"
tagged_runtime=$(jq -n --arg host "${first}" --arg ref "${image}:${first_canonical#*:}" '{$host: $ref}')
make_record "${revision}" "${tagged_runtime}" "${aliases_one}" '[]'
run_promote 'does not address the published image by digest'
if wrote_anything; then
  echo 'a runtime value that is not digest-addressed must not reach the registry' >&2
  exit 1
fi

# A truncated or absent packaging revision means the canonical names cannot be re-derived, so nothing
# here is known to be a name this build won. Refused before any registry traffic.
wipe_registry
make_record "${revision:0:7}" "${runtime_one}" "${aliases_one}" '[]'
run_promote 'names no full packaging commit'
if wrote_anything; then
  echo 'a truncated revision must not reach the registry' >&2
  exit 1
fi
make_record none "${runtime_one}" "${aliases_one}" '[]'
run_promote 'names no full packaging commit'

# A missing record is a file check, not a jq error several calls later.
wipe_registry
run_promote 'no release record at' "${test_root}/does-not-exist.json"

# This script empties the directory it was given, so the directory has to be one where being emptied
# is the intent. Anything else is refused before the first read.
wipe_registry
put_index "${first_canonical}" "${verified_digest}"
put_index "${first_alias}" "${prior_digest}"
make_record "${revision}" "${runtime_one}" "${aliases_one}" '[]'
status=0
set +e
env PATH="${test_root}/bin:${PATH}" TMPDIR=/tmp \
  PROMOTE_ALIAS_RECORD_DIR="${test_root}" \
  DOCKER_MOCK_DIR="${registry_dir}" DOCKER_MOCK_LOG="${log_file}" \
  REGISTRY_RETRY_ATTEMPTS=2 REGISTRY_RETRY_INITIAL_DELAY=1 REGISTRY_RETRY_MAX_DELAY=1 \
  bash "${repository_root}/scripts/promote-runtime-aliases.sh" "${record_path}" \
  >"${test_root}/guard.stdout" 2>"${test_root}/guard.stderr"
status=$?
set -e
((status != 0)) || { echo 'a promotion directory outside alias-moves must be refused' >&2; exit 1; }
grep -q 'must be an absolute directory named alias-moves' "${test_root}/guard.stderr" || {
  echo 'the promotion directory guard reported something else' >&2
  cat "${test_root}/guard.stderr" >&2
  exit 1
}

echo 'alias-track promotion names, licensing, undo records, and refusals passed'
