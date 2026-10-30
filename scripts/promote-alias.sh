#!/usr/bin/env bash
#
# Point one or more moving aliases at a canonical tag that has already been verified.
#
# This is the second half of a two-phase publication. scripts/publish-index.sh writes the immutable
# tag only; this script moves the public names, and it moves them only at the digest the caller can
# prove was verified. That proof is re-checked against the registry here rather than trusted from the
# argument, because the argument is produced before the write and this is the last moment at which a
# move can still be refused.
#
# Every alias records the digest it held before the move, into a machine-readable record, so the
# repository has something to undo with. Without it a bad promotion is repaired by hand from memory.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

if (($# < 2)); then
  printf 'Usage: %s <canonical-reference> <verified-digest> [alias ...]\n' "${0##*/}" >&2
  exit 2
fi

canonical_ref=$1
verified_digest=$2
shift 2

require_command docker jq

[[ ${canonical_ref} == *:* && ${canonical_ref} != *@* ]] \
  || die "canonical reference must be a tag, not a digest: ${canonical_ref}"
[[ ${verified_digest} =~ ^sha256:[0-9a-f]{64}$ ]] \
  || die "verified digest is not a sha256: ${verified_digest}"
(($# > 0)) || die 'no aliases were supplied to promote'

for promoted in "$@"; do
  [[ ${promoted} == "${canonical_ref%:*}:"* ]] \
    || die "alias does not belong to the same repository as the canonical tag: ${promoted}"
  [[ ${promoted} != "${canonical_ref}" ]] || die 'the canonical tag must not be promoted as an alias'
done

# The permission to move: the name the caller verified must still hold exactly the content it was
# verified to hold. A canonical tag that moved while verification ran is no longer evidence about
# anything, and an alias pointed at it would advertise content nothing checked.
live_digest=$(image_manifest_digest "${canonical_ref}" true) \
  || die "canonical tag is not a complete two-architecture index: ${canonical_ref}"
[[ ${live_digest} == "${verified_digest}" ]] \
  || die "canonical tag ${canonical_ref} now resolves to ${live_digest}, not the verified ${verified_digest}; refusing to promote any alias"

record=${PROMOTE_ALIAS_RECORD:-}
if [[ -n ${record} ]]; then
  jq -n --arg canonical_ref "${canonical_ref}" --arg digest "${verified_digest}" '
    {schema_version:1,canonical_ref:$canonical_ref,canonical_digest:$digest,moves:[]}
  ' >"${record}"
fi

# Each move is recorded as it happens, not at the end: if the second alias fails to promote, the
# record still says where the first one used to point, which is exactly when an undo is needed.
record_move() {
  local held_alias=$1 held_from=$2 held_to=$3 tmp
  [[ -n ${record} ]] || return 0
  tmp=$(mktemp "${record}.XXXXXX")
  jq --arg alias "${held_alias}" --arg from "${held_from}" --arg to "${held_to}" '
    .moves += [{alias:$alias, from:$from, to:$to}]
  ' "${record}" >"${tmp}"
  mv -- "${tmp}" "${record}"
}

# Previous positions are captured before any move, so the record describes the state this script
# changed rather than the state it left behind. An alias that does not resolve yet is recorded as
# absent: undoing its first promotion means deleting it, not pointing it at a digest that never was.
declare -A previous=()
for promoted in "$@"; do
  if from=$(image_reference_digest "${promoted}"); then
    previous[${promoted}]=${from}
  else
    status=$?
    ((status == 1)) || die "could not read the digest currently held by ${promoted} (exit ${status})"
    previous[${promoted}]=absent
  fi
done

for promoted in "$@"; do
  log "Promoting ${promoted} from ${previous[${promoted}]} to ${live_digest}"
  retry_command 4 2 docker buildx imagetools create --tag "${promoted}" "${canonical_ref%:*}@${live_digest}"
  moved=$(image_manifest_digest "${promoted}" true) \
    || die "alias ${promoted} is not a complete two-architecture index after promotion"
  [[ ${moved} == "${live_digest}" ]] \
    || die "alias ${promoted} resolves to ${moved} after promotion, expected ${live_digest}"
  record_move "${promoted}" "${previous[${promoted}]}" "${moved}"
done

log "Promoted $# alias(es) to ${live_digest}"
