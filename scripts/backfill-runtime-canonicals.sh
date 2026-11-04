#!/usr/bin/env bash
#
# Give the bytes that were published before per-build canonical names existed the name the naming
# function would have given them, so that a retired runtime cast stays addressable by name after the
# moving alias has already gone on to a newer build.
#
# The plan lists digests, not names to invent. Every name is recomputed here from the packaging
# revision the image itself carries, and an entry is refused unless:
#
#   * its digest and revision are well formed and the revision is a commit of this checkout;
#   * the bytes at that digest carry that same revision in their own child config;
#   * those bytes label the same product version the current lock releases;
#   * the planned name equals what `render tags` derives for that revision, and the alias it was
#     displaced from equals the alias the same derivation produces;
#   * the target name is absent, or already holds exactly these bytes.
#
# A target that holds other bytes is a refusal, never a move. This script cannot rewrite a published
# name, and that is the one rule the whole naming scheme rests on.
#
# Modes:
#   check              read-only against the registry, writes nothing (the default)
#   apply              writes, and only with PLUGIN_ABI_BACKFILL_APPLY=1
#   derivation-only    validates the plan against this checkout and the naming function alone, with
#                      no registry call, so the offline suite can grade a committed plan
#
# The record says which moment it describes: `read-only` for a run that writes nothing, `pre-write` for
# the classification an apply run made before attempting anything, `post-write` for the reads taken after
# the writes. An entry that has not been read says `digest_matches: null` rather than `false`, so a run
# that dies among its writes leaves a record that cannot accuse a name nobody checked.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

mode=${1:-check}
[[ ${mode} == check || ${mode} == apply || ${mode} == derivation-only ]] \
  || die "mode must be check, apply or derivation-only: ${mode}"

plan=${PLUGIN_ABI_BACKFILL_PLAN:-${repository_root}/plugin-abi-backfill.json}
record=${PLUGIN_ABI_BACKFILL_RECORD:-${repository_root}/tmp/plugin-abi-backfill-report.json}
owner=${GITHUB_REPOSITORY_OWNER:-}
owner=${owner,,}
[[ -f ${plan} ]] || die "no backfill plan at ${plan}"

if [[ ${mode} == apply ]]; then
  [[ ${PLUGIN_ABI_BACKFILL_APPLY:-} == 1 ]] \
    || die 'apply requires PLUGIN_ABI_BACKFILL_APPLY=1, because this mode writes published names'
  [[ -n ${owner} ]] || die 'apply requires GITHUB_REPOSITORY_OWNER to name the published owner'
fi
if [[ ${mode} == check || ${mode} == apply ]]; then
  require_command docker
fi

release_version=$(jq -er '.abi.rulego_server.release_version' "${repository_root}/plugin-abi.lock")
runtime_image=$(jq -er '.release.runtime_image' "${repository_root}/plugin-abi.lock")
locked_hosts=$(jq -r '.abi.build.hosts[].id' "${repository_root}/plugin-abi.lock" | sort -u | paste -sd, -)

# `cast_config_label` and `index_annotation` come from lib.sh, which needs the same reads to date a
# published generation; a second copy here would be a second thing to keep correct.

derive_names() {
  local revision=${1:?packaging revision is required} host=${2:?host id is required}
  PLUGIN_ABI_NAME_REVISION="${revision}" "${script_dir}/plugin-abi.sh" render tags \
    | jq -er --arg h "${host}" '{canonical: .runtime[$h].canonical, alias: .runtime[$h].alias}'
}

count=$(jq -r '.entries | length' "${plan}")
(( count > 0 )) || die 'the plan holds no entries'

actions=()
for ((index = 0; index < count; index += 1)); do
  entry=$(jq -c --argjson i "${index}" '.entries[$i]' "${plan}")
  host=$(jq -er '.host' <<<"${entry}")
  digest=$(jq -er '.digest' <<<"${entry}")
  revision=$(jq -er '.packaging_revision' <<<"${entry}")
  planned=$(jq -er '.canonical_ref' <<<"${entry}")
  displaced=$(jq -er '.displaced_alias' <<<"${entry}")

  [[ ${digest} =~ ^sha256:[0-9a-f]{64}$ ]] || die "entry ${host}: the digest is not a sha256"
  [[ ${revision} =~ ^[0-9a-f]{40}$ ]] || die "entry ${host}: the packaging revision is not 40 hex"
  [[ ,${locked_hosts}, == *",${host},"* ]] || die "entry ${host}: not a host of the current lock"
  git cat-file -e "${revision}^{commit}" 2>/dev/null \
    || die "entry ${host}: that revision is not a commit of this checkout"

  derived=$(derive_names "${revision}" "${host}")
  want_canonical=$(jq -er '.canonical' <<<"${derived}")
  want_alias=$(jq -er '.alias' <<<"${derived}")
  # The name must be derived, and derived into the repository this contract publishes.
  [[ ${planned} == "${planned%:*}:${want_canonical##*:}" ]] \
    || die "entry ${host}: the plan names ${planned##*:}, the naming function produces ${want_canonical##*:}"
  if [[ -n ${owner} ]]; then
    [[ ${planned%:*} == "ghcr.io/${owner}/${runtime_image}" ]] \
      || die "entry ${host}: the plan writes into ${planned%:*}, where this contract publishes nothing"
  else
    [[ ${planned%:*} == */"${runtime_image}" ]] \
      || die "entry ${host}: the plan writes into a repository other than ${runtime_image}"
  fi
  [[ ${displaced} == "${displaced%:*}:${want_alias##*:}" ]] \
    || die "entry ${host}: the alias for that revision is ${want_alias##*:}, the plan says ${displaced##*:}"
  # Nothing compares `planned` with `displaced`: each is checked against the naming function above,
  # and the function's two names for one host differ by the revision suffix, so equality there is not a
  # state a plan can express. A guard that no input can reach would only ever be tested by deleting it.

  if [[ ${mode} == derivation-only ]]; then
    actions+=( "$(jq -cn --arg h "${host}" --arg c "${planned}" --arg d "${digest}" \
      '{host:$h, canonical_ref:$c, digest:$d, action:"derived"}')" )
    continue
  fi

  # Both reads are failures of the question, not answers of "no": a registry that will not talk must
  # never be read as bytes that disagree, and certainly not as a name that is free.
  if ! cast_revision=$(cast_config_label "${planned%:*}" "${digest}" org.opencontainers.image.revision); then
    die "entry ${host}: the registry could not answer what those bytes carry, and silence is not evidence"
  fi
  [[ ${cast_revision} == "${revision}" ]] \
    || die "entry ${host}: those bytes carry a different packaging revision than the plan names"
  if ! cast_release=$(index_annotation "${planned%:*}@${digest}" io.rulego.server.release); then
    die "entry ${host}: the registry could not answer what release those bytes are, and silence is not evidence"
  fi
  [[ ${cast_release} == "${release_version}" ]] \
    || die "entry ${host}: those bytes are release ${cast_release}, the contract releases ${release_version}"

  status=0
  holding=$(image_reference_digest "${planned}") || status=$?
  case ${status} in
    0)
      [[ ${holding} == "${digest}" ]] \
        || die "entry ${host}: that name already holds other bytes, and a published name is never moved"
      log "entry ${host}: the name already holds exactly these bytes"
      actions+=( "$(jq -cn --arg h "${host}" --arg c "${planned}" --arg d "${digest}" \
        '{host:$h, canonical_ref:$c, digest:$d, action:"noop", digest_matches:true}')" )
      ;;
    1)
      # `null`, not `false`: nothing has read this name back yet, and a record that says false states an
      # observation that did not happen. This file is replaced below by the post-write record, but a run
      # that dies in between still uploads it, and then only `null` keeps it from accusing a name that
      # in fact holds the bytes.
      actions+=( "$(jq -cn --arg h "${host}" --arg c "${planned}" --arg d "${digest}" \
        '{host:$h, canonical_ref:$c, digest:$d, action:"mint", digest_matches:null}')" )
      ;;
    *)
      die "entry ${host}: the registry could not answer whether the name exists, and absence is not a default"
      ;;
  esac
done

mkdir -p "$(dirname -- "${record}")"
# An array of entry objects is built by handing the objects to `jq -s` and letting it parse them, not by
# joining strings with a separator. A join that yields valid JSON for one entry yields invalid JSON for
# two, and two is the ordinary number of hosts here -- so the shape of the record has to be something
# other than luck.
json_array() {
  printf '%s\n' "$@" | jq -sc '.'
}

entries_json=$(json_array "${actions[@]}")
[[ $(jq 'length' <<<"${entries_json}") == "${count}" ]] \
  || die 'internal: the record does not hold one entry per plan entry'
# A record says which moment it describes. `read-only` never writes, so its entries are plain reads;
# `pre-write` is what an apply run leaves behind if it dies among the writes, and its unread entries say
# null. Only `post-write` may claim what a name resolves to now.
if [[ ${mode} == apply ]]; then stage=pre-write; else stage=read-only; fi
jq -n --arg mode "${mode}" --arg plan "${plan##*/}" --arg stage "${stage}" \
  --argjson entries "${entries_json}" \
  '{mode:$mode, plan:$plan, stage:$stage, entries:$entries}' | jq -S '.' > "${record}"

if [[ ${mode} != apply ]]; then
  log "$(jq -r '[.entries[].action] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "${record}")"
  exit 0
fi

for entry_json in "${actions[@]}"; do
  [[ $(jq -r '.action' <<<"${entry_json}") == mint ]] || continue
  host=$(jq -r '.host' <<<"${entry_json}")
  target=$(jq -r '.canonical_ref' <<<"${entry_json}")
  digest=$(jq -r '.digest' <<<"${entry_json}")
  log "entry ${host}: minting ${target##*:}"
  # A refused write names the entry it refused, because the run stops here and the record left behind is
  # the one written before anything was attempted.
  docker buildx imagetools create --tag "${target}" "${target%:*}@${digest}" \
    || die "entry ${host}: the registry refused the write for ${target##*:}"
  now=$(image_reference_digest "${target}") || die "entry ${host}: written and unreadable"
  [[ ${now} == "${digest}" ]] || die "entry ${host}: the new name resolves to other bytes"
done

# Every entry is read again, including the ones that were already right, and the record's answer is
# that read rather than anything this run predicted. A record that says a name holds these bytes
# because a write command exited zero is not evidence; the name is checked, and a failure is reported
# in the record before it is reported on the console.
results=()
for entry_json in "${actions[@]}"; do
  host=$(jq -r '.host' <<<"${entry_json}")
  target=$(jq -r '.canonical_ref' <<<"${entry_json}")
  digest=$(jq -r '.digest' <<<"${entry_json}")
  read_back=''
  status=0
  read_back=$(image_reference_digest "${target}") || status=$?
  matches=false
  [[ ${status} == 0 && ${read_back} == "${digest}" ]] && matches=true
  results+=( "$(jq -cn --arg h "${host}" --arg c "${target}" --arg d "${digest}" --argjson m "${matches}" \
    '{host:$h, canonical_ref:$c, digest:$d, digest_matches:$m}')" )
done
results_json=$(json_array "${results[@]}")
[[ $(jq 'length' <<<"${results_json}") == "${count}" ]] \
  || die 'internal: every entry was not read back'
merged=$(jq -n --argjson a "${entries_json}" --argjson r "${results_json}" \
  '{entries: [ $a[] as $e | ($r[] | select(.canonical_ref == $e.canonical_ref)) as $v | $e + {digest_matches: $v.digest_matches} ]}')
# A name missing from the read-back would drop out of the merged array rather than fail, and a record
# with fewer entries than the plan is not a proof about the plan.
[[ $(jq '.entries | length' <<<"${merged}") == "${count}" ]] \
  || die 'internal: a written name was not read back'
jq -n --arg mode "${mode}" --arg plan "${plan##*/}" --arg stage post-write \
  --argjson merged "${merged}" \
  '{mode:$mode, plan:$plan, stage:$stage, entries:$merged.entries}' | jq -S '.' > "${record}"
if [[ $(jq -r '[.entries[] | select(.digest_matches | not)] | length' "${record}") != 0 ]]; then
  jq -r '.entries[] | select(.digest_matches | not) | "entry \(.host): \(.canonical_ref) does not resolve to these bytes"' \
    "${record}" >&2
  die 'the backfill did not leave every named entry holding the bytes the plan describes'
fi
log "backfill applied: $(jq -r '[.entries[].action] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "${record}")"
