#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${repository_root}/scripts/lib.sh"

mkdir -p "${repository_root}/tmp"
test_root=$(mktemp -d "${repository_root}/tmp/plugin-publication-policy.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

expected=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
other=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
target=registry.example:5000/rulego-server:abi-test-plugin
source_ref=registry.example:5000/rulego-server@${expected}
state=${test_root}/published
docker_log=${test_root}/docker.log

image_reference_digest() {
  case ${MOCK_TAG_STATE:?} in
    matching) printf '%s\n' "${expected}" ;;
    mismatched) printf '%s\n' "${other}" ;;
    absent)
      [[ -f ${state} ]] || return 1
      printf '%s\n' "${expected}"
      ;;
    error) return 2 ;;
  esac
}

docker() {
  if [[ $1 == buildx && $2 == imagetools && $3 == create ]]; then
    printf '%q ' "$@" >>"${docker_log}"
    printf '\n' >>"${docker_log}"
    touch "${state}"
    return
  fi
  if [[ $1 == buildx && $2 == imagetools && $3 == inspect ]]; then
    if [[ -n ${MOCK_HELD_BY:-} ]]; then
      printf '{"annotations":{"io.rulego.abi.id":"%s"}}\n' "${MOCK_HELD_BY}"
      return
    fi
    if [[ ${MOCK_INDEX_STATE:?} == complete ]]; then
      printf '{"manifests":[{"platform":{"os":"linux","architecture":"arm64"},"digest":"%s"},{"platform":{"os":"linux","architecture":"amd64"},"digest":"%s"}]}\n' \
        "${other}" "${expected}"
    else
      printf '{"manifests":[{"platform":{"os":"linux","architecture":"amd64"},"digest":"%s"}]}\n' \
        "${expected}"
    fi
    return
  fi
  printf 'unexpected docker command:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  return 64
}

MOCK_TAG_STATE=matching
export MOCK_TAG_STATE
result=$(publish_immutable_image_tag "${target}" "${source_ref}")
[[ ${result} == "registry.example:5000/rulego-server@${expected}" && ! -e ${docker_log} ]]

MOCK_TAG_STATE=absent
rm -f -- "${state}" "${docker_log}"
result=$(publish_immutable_image_tag "${target}" "${source_ref}")
[[ ${result} == "registry.example:5000/rulego-server@${expected}" ]]
[[ $(wc -l <"${docker_log}") == 1 ]]

for mode in mismatched error; do
  MOCK_TAG_STATE=${mode}
  rm -f -- "${state}" "${docker_log}"
  if (publish_immutable_image_tag "${target}" "${source_ref}") >"${test_root}/stdout" 2>"${test_root}/stderr"; then
    printf 'expected immutable publication failure for %s\n' "${mode}" >&2
    exit 1
  fi
  [[ ! -e ${docker_log} ]]
  if [[ ${mode} == mismatched ]]; then
    grep -Fq 'immutable tag already points to a different digest' "${test_root}/stderr"
  fi
done

MOCK_INDEX_STATE=complete
export MOCK_INDEX_STATE
verify_exact_image_children test@index "${expected}" "${other}" "${test_root}/index.json"
MOCK_INDEX_STATE=incomplete
if verify_exact_image_children test@index "${expected}" "${other}" "${test_root}/index.json"; then
  echo 'expected incomplete image index failure' >&2
  exit 1
fi

canonical_plan=${test_root}/canonical-plan.tsv
printf '%s\t%s\t%s\n%s\t%s\t%s\n' \
  registry.example:5000/rulego-plugin-sdk:abi-test "${source_ref}" plugin-sdk \
  "${target}" "registry.example:5000/rulego-server@${expected}" runtime-plugin >"${canonical_plan}"

# All canonical tags absent: the plan is publishable and nothing is written.
MOCK_TAG_STATE=absent
require_immutable_tags_publishable "${canonical_plan}"
[[ ! -e ${docker_log} ]]

# One existing tag already points elsewhere: fail before any write, naming both
# the conflicting identity and the revision that owns the tag.
MOCK_TAG_STATE=mismatched
rm -f -- "${state}" "${docker_log}"
if (require_immutable_tags_publishable "${canonical_plan}") >"${test_root}/stdout" 2>"${test_root}/stderr"; then
  echo 'expected canonical tag conflict before publication' >&2
  exit 1
fi
[[ ! -e ${docker_log} ]]
grep -Fq 'no tag written' "${test_root}/stderr"
grep -Fq 'runtime-plugin' "${test_root}/stderr"

# An unpublished canonical tag whose sibling holds this release's digest stays
# publishable, so a rerun of the revision that first published it succeeds.
MOCK_TAG_STATE=matching
require_immutable_tags_publishable "${canonical_plan}"
[[ ! -e ${docker_log} ]]

# A registry that cannot answer is not treated as absent.
MOCK_TAG_STATE=error
if (require_immutable_tags_publishable "${canonical_plan}") 2>"${test_root}/stderr"; then
  echo 'expected canonical tag inspection failure' >&2
  exit 1
fi
[[ ! -e ${docker_log} ]]

if (require_immutable_tags_publishable "${test_root}/missing-plan.tsv") 2>/dev/null; then
  echo 'expected missing canonical tag plan failure' >&2
  exit 1
fi

# The publication decision is a pure function of probe facts, so every branch is checkable
# without a registry. These vectors pin the rule that decides whether a blocked name really
# blocks: `superseded` must be the only occupied-but-publishable verdict, and it must be reached
# from the identity the lock records, never from a digest guess.
this_abi=abi-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
prev_abi=abi-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
want=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
other=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

decision_case() {
  local description=$1 want_out=$2; shift 2
  local actual
  actual=$(canonical_tag_publish_decision "$@") || {
    printf 'decision function failed for: %s\n' "${description}" >&2
    exit 1
  }
  [[ ${actual} == "${want_out}" ]] || {
    printf 'decision mismatch for %s: expected %s, got %s\n' \
      "${description}" "${want_out}" "${actual}" >&2
    exit 1
  }
}

decision_case 'free name' publish absent '' "" "${want}" "${this_abi}" "${prev_abi}"
decision_case 'already ours bit-for-bit' noop occupied "${this_abi}" "${want}" "${want}" "${this_abi}" "${prev_abi}"
decision_case 'earlier contract owns it' superseded occupied "${prev_abi}" "${other}" "${want}" "${this_abi}" "${prev_abi}"
decision_case 'same abi different bytes' identity-conflict occupied "${this_abi}" "${other}" "${want}" "${this_abi}" "${prev_abi}"
decision_case 'holder the lock cannot name' collision occupied 'abi-99999999' "${other}" "${want}" "${this_abi}" "${prev_abi}"
decision_case 'registry silent' unreachable unreachable '' "${other}" "${want}" "${this_abi}" "${prev_abi}"

# A lock with no recorded predecessor has nothing to be superseded by: the older name is then an
# unexplained holder, not a satisfied one. Falling through to collision here is the difference
# between a contract fact and a guess.
decision_case 'no predecessor recorded' collision occupied "${prev_abi}" "${other}" "${want}" "${this_abi}" ""

# The gate's real job: a name owned by the contract this lock supersedes must not hold the rest of
# the batch hostage. These two lines are one batch where the runtime tag belongs to the lock's
# recorded predecessor and the SDK tag is this build's, so the old digest-only rule refused both.
superseded_plan=${test_root}/superseded-plan.tsv
printf '%s\t%s\t%s\n%s\t%s\t%s\n' \
  registry.example:5000/rulego-plugin-sdk:abi-test "${source_ref}" plugin-sdk \
  registry.example:5000/rulego-server:v1.0.0-plugin "registry.example:5000/rulego-server@${expected}" runtime-plugin \
  >"${superseded_plan}"

# Registry stand-in: the SDK name is free, the runtime name resolves to bytes that are not this
# build's. Which identity owns it is supplied per case through MOCK_HELD_BY.
registry_mock() {
  case ${1:-} in
    *:abi-test) return 1 ;;
    *) printf '%s\n' "${other}" ;;
  esac
}

MOCK_HELD_BY=$(jq -er '.compatibility.previous_sdk.abi_id' "${repository_root}/plugin-abi.lock")
rm -f -- "${state}" "${docker_log}"
image_reference_digest() { registry_mock "${1:-}"; }
gate_out=$(require_immutable_tags_publishable "${superseded_plan}") || {
  echo 'a superseded canonical name must not block its batch' >&2
  exit 1
}
[[ ! -e ${docker_log} ]]
printf '%s\n' "${gate_out}" | grep -Fq 'runtime-plugin	superseded' || {
  echo 'the gate did not report the superseded host to its caller' >&2
  exit 1
}
unset MOCK_HELD_BY

# A holder the lock accounts for in neither way still refuses everything, and says who.
MOCK_HELD_BY=abi-0000000000000000000000000000000000000000000000000000000000000000
rm -f -- "${state}" "${docker_log}"
if (require_immutable_tags_publishable "${superseded_plan}") >"${test_root}/unexplained.out" 2>"${test_root}/stderr"; then
  echo 'expected an unexplained canonical holder to block the batch' >&2
  exit 1
fi
[[ ! -e ${docker_log} ]]
grep -Fq 'collision' "${test_root}/stderr"

# Same identity, different bytes: two packaging revisions of one contract reached for the same
# immutable name. Supersession does not cover this, and reading it as satisfied would quietly
# point a published name at content the lock never produced.
MOCK_HELD_BY=$(jq -er '.abi_id' "${repository_root}/plugin-abi.lock")
rm -f -- "${state}" "${docker_log}"
if (require_immutable_tags_publishable "${superseded_plan}") 2>"${test_root}/self.out"; then
  echo 'expected the same identity under a different digest to block' >&2
  exit 1
fi
grep -Fq 'identity-conflict' "${test_root}/self.out"
unset MOCK_HELD_BY

# The two readers of the gate's verdict lines are pure, so their contract is pinned without a
# registry. Inputs are built with printf so the tab separator is a real byte, not a literal.
host_case() {
  local description=$1 want=$2 actual
  actual=$(canonical_superseded_hosts "${3-}")
  [[ ${actual} == "${want}" ]] || {
    printf 'superseded-host extraction wrong for %s: expected %s, got %s\n' \
      "${description}" "${want}" "${actual}" >&2
    exit 1
  }
}

rows() { printf '%s\t%s\n' "$@"; }

host_case 'empty input' '[]' ''
host_case 'no superseded rows' '[]' "$(rows plugin-sdk publish runtime-plugin noop)"
host_case 'one host drops' '["ai-plugin"]' "$(rows plugin-sdk publish runtime-ai-plugin superseded)"
host_case 'both hosts drop, prefix stripped once' '["plugin","ai-plugin"]' \
  "$(rows plugin-sdk publish runtime-plugin superseded runtime-ai-plugin superseded)"

# The SDK guard passes whenever the SDK is not the one being superseded, and fails only then.
canonical_sdk_superseded "$(rows plugin-sdk publish runtime-plugin superseded)" || {
  echo 'SDK guard must tolerate a superseded runtime host' >&2
  exit 1
}
canonical_sdk_superseded '' || {
  echo 'SDK guard must tolerate an empty verdict set' >&2
  exit 1
}
if canonical_sdk_superseded "$(rows plugin-sdk superseded runtime-plugin publish)"; then
  echo 'SDK guard must reject a release that would skip its own SDK' >&2
  exit 1
fi

echo 'Plugin publication immutability and platform policy passed'
