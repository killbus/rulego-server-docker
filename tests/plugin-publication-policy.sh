#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${repository_root}/scripts/lib.sh"

test_root=$(mktemp -d "${repository_root}/tmp/plugin-publication-policy.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

expected=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
other=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
target=registry.example:5000/rulego-server:abi-test-plugin
alias=registry.example:5000/rulego-server:v1.0.0-plugin
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
    promoted)
      if [[ -f ${state} ]]; then printf '%s\n' "${expected}"; else printf '%s\n' "${other}"; fi
      ;;
    sticky-mismatch) printf '%s\n' "${other}" ;;
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

# The alias is mutable: a matching digest is a no-op, an absent alias is
# created once, and a stale alias is moved to the already-verified canonical
# digest exactly once.
MOCK_TAG_STATE=matching
rm -f -- "${state}" "${docker_log}"
result=$(promote_image_alias "${alias}" "${source_ref}")
[[ ${result} == "${alias}@${expected}" && ! -e ${docker_log} ]]

MOCK_TAG_STATE=absent
rm -f -- "${state}" "${docker_log}"
result=$(promote_image_alias "${alias}" "${source_ref}")
[[ ${result} == "${alias}@${expected}" ]]
[[ $(wc -l <"${docker_log}") == 1 ]]

MOCK_TAG_STATE=promoted
rm -f -- "${state}" "${docker_log}"
result=$(promote_image_alias "${alias}" "${source_ref}" 2>"${test_root}/stderr")
[[ ${result} == "${alias}@${expected}" ]]
[[ $(wc -l <"${docker_log}") == 1 ]]
grep -Fq 'promoting alias' "${test_root}/stderr"

MOCK_TAG_STATE=sticky-mismatch
rm -f -- "${state}" "${docker_log}"
if (promote_image_alias "${alias}" "${source_ref}") >"${test_root}/stdout" 2>"${test_root}/stderr"; then
  echo 'expected alias read-back mismatch failure' >&2
  exit 1
fi
[[ $(wc -l <"${docker_log}") == 1 ]]
grep -Fq 'alias digest changed during promotion' "${test_root}/stderr"

MOCK_TAG_STATE=error
rm -f -- "${state}" "${docker_log}"
if (promote_image_alias "${alias}" "${source_ref}") >"${test_root}/stdout" 2>"${test_root}/stderr"; then
  echo 'expected alias lookup error to propagate' >&2
  exit 1
fi
[[ ! -e ${docker_log} ]]

MOCK_TAG_STATE=matching
if (promote_image_alias "${alias}@${expected}" "${source_ref}") >"${test_root}/stdout" 2>"${test_root}/stderr"; then
  echo 'expected a digest alias to be rejected' >&2
  exit 1
fi
grep -Fq 'alias must be a tag reference' "${test_root}/stderr"

if (promote_image_alias "${alias}" "${alias}") >"${test_root}/stdout" 2>"${test_root}/stderr"; then
  echo 'expected a tag source to be rejected' >&2
  exit 1
fi
grep -Fq 'source image must be addressed by digest' "${test_root}/stderr"

MOCK_INDEX_STATE=complete
export MOCK_INDEX_STATE
verify_exact_image_children test@index "${expected}" "${other}" "${test_root}/index.json"
MOCK_INDEX_STATE=incomplete
if verify_exact_image_children test@index "${expected}" "${other}" "${test_root}/index.json"; then
  echo 'expected incomplete image index failure' >&2
  exit 1
fi

echo 'Plugin publication immutability, alias promotion, and platform policy passed'
