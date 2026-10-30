#!/usr/bin/env bash
#
# Offline guards for scripts/promote-alias.sh, the second half of the two-phase publication.
#
# The property under test is a permission, not a format: an alias may move only at a digest a verifier
# has confirmed the canonical tag still holds. The refusals are the cases that matter, because a
# promotion that cannot fail is the write the pipeline used to perform unconditionally.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/rulego-alias-promotion-test.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

mkdir -p "${test_root}/bin" "${test_root}/registry"

image=registry.example:5000/rulego-server
canonical_ref=${image}:v1.2.3
alias_ref=${image}:latest
verified_digest=sha256:$(printf 'a%.0s' {1..64})
drifted_digest=sha256:$(printf 'b%.0s' {1..64})
prior_digest=sha256:$(printf 'c%.0s' {1..64})
mismatch_digest=sha256:$(printf 'e%.0s' {1..64})

log_file=${test_root}/docker.log
export DOCKER_MOCK_LOG=${log_file}
export DOCKER_MOCK_DIR="${test_root}/registry"

# A registry that answers like `docker buildx imagetools`: every reference resolves through a file of
# index JSON, a write stores what the registry now holds for that tag, and MOCK_WRONG_DIGEST makes one
# tag answer differently from what was written. That last knob is what lets a test model a promotion
# that lands somewhere unexpected, which no mock built only for the happy path would have surfaced.
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
  printf '%s/%s' "${test_root}/registry" "$(printf '%s' "${1##*/}" | tr ':@' '__')"
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

reset_registry() {
  rm -rf -- "${test_root}/registry"
  mkdir -p "${test_root}/registry"
  : >"${log_file}"
  put_index "${canonical_ref}" "${verified_digest}"
}

run_promote() {
  local expected=$1
  shift
  local status=0
  set +e
  env PATH="${test_root}/bin:${PATH}" \
    TMPDIR=/tmp \
    PROMOTE_ALIAS_RECORD="${RECORD:-}" \
    MOCK_WRONG_DIGEST="${MOCK_WRONG_DIGEST:-}" \
    MOCK_WRONG_WRITE="${MOCK_WRONG_WRITE:-}" \
    MOCK_MISMATCH_DIGEST="${mismatch_digest}" \
    REGISTRY_RETRY_ATTEMPTS=2 REGISTRY_RETRY_INITIAL_DELAY=1 REGISTRY_RETRY_MAX_DELAY=1 \
    bash "${repository_root}/scripts/promote-alias.sh" "$@" \
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
    exit 1
  }
  grep -q -- "${expected}" "${test_root}/stderr"
}

# Malformed arguments are caller bugs and are refused before any registry traffic, so a typo does not
# cost a probe pass to report itself. TMPDIR is pointed at a directory that does not exist: if the
# script reached the registry it would fail there instead, with a different message.
status=0
(
  cd "${repository_root}"
  env PATH="${test_root}/bin:${PATH}" TMPDIR=/nonexistent-for-this-test \
    bash scripts/promote-alias.sh "${canonical_ref}"
) >"${test_root}/usage.stdout" 2>"${test_root}/usage.stderr" || status=$?
((status == 2)) || { printf 'expected exit 2 for one argument, got %s\n' "${status}" >&2; exit 1; }
grep -q 'Usage: promote-alias.sh <canonical-reference> <verified-digest> \[alias ...\]' "${test_root}/usage.stderr"

# The shape a failed verification actually produces downstream: the verify step dies before writing
# its licence, so the promotion step receives an empty digest. Refusing on format is what stops an
# unset step output from reaching the registry as a writable value.
reset_registry
put_index "${alias_ref}" "${prior_digest}"
run_promote 'verified digest is not a sha256' "${canonical_ref}" "" "${alias_ref}"
if grep -q -- 'imagetools create' "${log_file}"; then
  echo 'an absent licence must not reach the registry' >&2
  exit 1
fi

reset_registry
run_promote 'verified digest is not a sha256' "${canonical_ref}" "sha256:nope" "${alias_ref}"
run_promote 'canonical reference must be a tag' "${image}@${verified_digest}" "${verified_digest}" "${alias_ref}"
run_promote 'no aliases were supplied to promote' "${canonical_ref}" "${verified_digest}"
run_promote 'must not be promoted as an alias' "${canonical_ref}" "${verified_digest}" "${canonical_ref}"
run_promote 'does not belong to the same repository' "${canonical_ref}" "${verified_digest}" "other.example:5000/x:latest"
if grep -q -- 'imagetools create' "${log_file}"; then
  echo 'argument validation must not reach the registry' >&2
  exit 1
fi

# The refusal the single-write assembly could not express: the canonical tag no longer holds what the
# verifier confirmed, so nothing may move. This is the whole point of re-checking instead of trusting
# the digest handed over as an argument.
reset_registry
put_index "${canonical_ref}" "${drifted_digest}"
put_index "${alias_ref}" "${prior_digest}"
run_promote 'refusing to promote any alias' "${canonical_ref}" "${verified_digest}" "${alias_ref}"
if grep -q -- 'imagetools create' "${log_file}"; then
  echo 'a refused promotion must write nothing' >&2
  exit 1
fi
# The alias stayed where it was: a partial move would be worse than no move.
grep -q -- "\"digest\": \"${prior_digest}\"" "$(registry_path "${alias_ref}")" || {
  echo 'the refused alias must keep its previous digest' >&2
  exit 1
}

# A canonical tag that is missing, or present but only one-architecture, is refused rather than
# promoted, and says so differently from a drift. Both states mean the name holds nothing a verifier
# could have confirmed, so the permission to move an alias was never granted.
reset_registry
rm -f -- "$(registry_path "${canonical_ref}")"
run_promote 'not a complete two-architecture index' "${canonical_ref}" "${verified_digest}" "${alias_ref}"
reset_registry
jq -n --arg digest "${verified_digest}" '{
  mediaType: "application/vnd.oci.image.index.v1+json",
  digest: $digest,
  manifests: [{digest: $digest, platform: {os: "linux", architecture: "amd64"}}]
}' >"$(registry_path "${canonical_ref}")"
run_promote 'not a complete two-architecture index' "${canonical_ref}" "${verified_digest}" "${alias_ref}"
if grep -q -- 'imagetools create' "${log_file}"; then
  echo 'a one-architecture canonical tag must not be promoted to' >&2
  exit 1
fi

# Happy path: the alias is pointed at the verified digest by digest address, never by re-tagging the
# canonical name, so it does not silently follow the canonical tag if that moves later.
reset_registry
RECORD=${test_root}/record.json
put_index "${alias_ref}" "${prior_digest}"
run_promote '' "${canonical_ref}" "${verified_digest}" "${alias_ref}"
grep -q -- "--tag ${alias_ref} ${image}@${verified_digest}" "${log_file}" \
  || { echo 'the alias must be pointed at the verified digest, not at the canonical tag' >&2; exit 1; }

# The record is the only thing that makes a bad promotion reversible, so it must name where each alias
# used to point. `from` being the previous digest rather than the new one is the difference between a
# record that can undo a move and a record that describes it.
jq -e --arg canonical "${canonical_ref}" --arg digest "${verified_digest}" \
  --arg alias "${alias_ref}" --arg from "${prior_digest}" '
  .schema_version == 1 and
  .canonical_ref == $canonical and
  .canonical_digest == $digest and
  (.moves | length) == 1 and
  (.moves[0] | .alias == $alias and .from == $from and .to == $digest)
' "${RECORD}" >/dev/null || {
  printf 'unexpected promotion record: %s\n' "$(<"${RECORD}")" >&2
  exit 1
}

# A first promotion records `absent` instead of inventing a previous digest: undoing it means deleting
# the tag, not restoring a value that never existed.
reset_registry
RECORD=${test_root}/record-absent.json
run_promote '' "${canonical_ref}" "${verified_digest}" "${alias_ref}"
jq -e '.moves[0].from == "absent"' "${RECORD}" >/dev/null \
  || { echo 'a first promotion must record absent, not a fabricated digest' >&2; exit 1; }

# Two aliases in one call, where only the second lands somewhere unexpected. The record must still hold
# the first move: a failure halfway is exactly when an undo is needed, and a record written only at the
# end of the script would describe nothing.
reset_registry
RECORD=${test_root}/record-partial.json
fail_alias=${image}:latest-bad
put_index "${alias_ref}" "${prior_digest}"
MOCK_WRONG_WRITE=${fail_alias##*:}
run_promote 'after promotion, expected' "${canonical_ref}" "${verified_digest}" "${alias_ref}" "${fail_alias}"
MOCK_WRONG_WRITE=''
jq -e --arg alias "${alias_ref}" --arg digest "${verified_digest}" '
  (.moves | length) == 1 and (.moves[0].alias == $alias) and (.moves[0].to == $digest)
' "${RECORD}" >/dev/null || {
  printf 'the partial promotion lost its record: %s\n' "$(<"${RECORD}")" >&2
  exit 1
}

# The same knob seen from the read side: a registry that answers the post-write check with a digest
# that does not match what was written must be reported as a failed promotion, not accepted because
# the create command exited 0.
reset_registry
RECORD=${test_root}/record-readback.json
put_index "${alias_ref}" "${prior_digest}"
MOCK_WRONG_DIGEST=${alias_ref##*:}
run_promote 'resolves to' "${canonical_ref}" "${verified_digest}" "${alias_ref}"
MOCK_WRONG_DIGEST=''
jq -e '(.moves | length) == 0' "${RECORD}" >/dev/null || {
  printf 'a promotion that failed its readback must not be recorded as a move: %s\n' "$(<"${RECORD}")" >&2
  exit 1
}

echo 'alias promotion permission, digest addressing, and recovery-record cases passed'
