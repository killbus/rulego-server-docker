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

echo 'Plugin publication immutability and platform policy passed'
