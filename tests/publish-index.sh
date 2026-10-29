#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/rulego-publish-index-test.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

mkdir -p "${test_root}/bin" "${test_root}/digests"

amd64_digest=$(printf '1%.0s' {1..64})
arm64_digest=$(printf '2%.0s' {1..64})
image=registry.example:5000/rulego-server
version_tag="${image}:v1.2.3"
docker_log=${test_root}/docker.log

cat >"${test_root}/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $1 == buildx && $2 == imagetools && $3 == create ]]; then
  printf '%q ' "$@" >>"${MOCK_DOCKER_LOG}"
  printf '\n' >>"${MOCK_DOCKER_LOG}"
  exit 0
fi
printf 'unexpected docker invocation:' >&2
printf ' %q' "$@" >&2
printf '\n' >&2
exit 64
STUB

cat >"${test_root}/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${test_root}/bin/docker" "${test_root}/bin/sleep"

run_publish() {
  local expected=$1
  local digest_dir=${2:-"${test_root}/digests"}
  shift
  if (($# > 0)); then shift; fi
  local status=0
  set +e
  env \
    PATH="${test_root}/bin:${PATH}" \
    TMPDIR=/tmp \
    MOCK_DOCKER_LOG="${docker_log}" \
    TAGS="${TAGS}" \
    ANNOTATIONS="${ANNOTATIONS}" \
    GITHUB_OUTPUT="${GITHUB_OUTPUT:-}" \
    REGISTRY_RETRY_ATTEMPTS=2 REGISTRY_RETRY_INITIAL_DELAY=1 REGISTRY_RETRY_MAX_DELAY=1 \
    bash "${repository_root}/scripts/publish-index.sh" "${digest_dir}" "${image}" \
    >"${test_root}/stdout" 2>"${test_root}/stderr"
  status=$?
  set -e

  if [[ -z ${expected} ]]; then
    [[ $status -eq 0 ]] || {
      printf 'expected success, got exit %s\n' "${status}" >&2
      cat "${test_root}/stderr" >&2
      exit 1
    }
    return
  fi

  [[ $status -ne 0 ]] || {
    printf 'expected failure containing: %s\n' "${expected}" >&2
    exit 1
  }
  grep -q "${expected}" "${test_root}/stderr"
}

reset_digests() {
  rm -rf -- "${test_root}/digests"
  mkdir -p "${test_root}/digests"
}

write_digests() {
  reset_digests
  :>"${test_root}/digests/amd64.${amd64_digest}"
  :>"${test_root}/digests/arm64.${arm64_digest}"
}

TAGS="${version_tag}"
ANNOTATIONS=""

# Usage contract: the argument count is a deterministic caller error.
run_usage_case() {
  local status=0
  set +e
  (
    cd "${repository_root}"
    env PATH="${test_root}/bin:${PATH}" TAGS='unused' \
      scripts/publish-index.sh "$@"
  ) >"${test_root}/usage.stdout" 2>"${test_root}/usage.stderr"
  status=$?
  set -e
  ((status == 2)) || {
    printf 'expected exit 2 for %d argument(s), got %s\n' "$#" "${status}" >&2
    exit 1
  }
  grep -q 'Usage: publish-index.sh <digest-directory> <image-reference>' "${test_root}/usage.stderr"
}

run_usage_case
run_usage_case "${test_root}/digests"
run_usage_case "${test_root}/digests" "${image}" "${image}"

# Digest pairing guards.
run_publish 'digest directory is missing' "${test_root}/absent"
reset_digests
: >"${test_root}/digests/riscv64.${arm64_digest}"
run_publish 'unexpected digest file name'
reset_digests
printf 'not-a-digest\n' >"${test_root}/digests/amd64.zzz"
run_publish 'unexpected digest file name'
reset_digests
run_publish 'no image digest was published for amd64'
write_digests
rm -- "${test_root}/digests/arm64.${arm64_digest}"
run_publish 'no image digest was published for arm64'
reset_digests
: >"${test_root}/digests/amd64.${arm64_digest}"
: >"${test_root}/digests/arm64.${arm64_digest}"
run_publish 'resolve to the same image digest'
write_digests
: >"${test_root}/digests/amd64.$(printf '3%.0s' {1..64})"
run_publish 'duplicate digest entry for amd64'

# Tag guards.
write_digests
ANNOTATIONS=""
TAGS="
"
run_publish 'no image tags were supplied'
TAGS="registry.other/example:v1.2.3"
run_publish 'first image tag does not belong to'

# Successful assembly keeps both tags and passes metadata annotations through
# without adding a second index level prefix.
TAGS="${version_tag}
${image}:latest"
ANNOTATIONS="index:org.opencontainers.image.version=v1.2.3"
rm -f -- "${docker_log}"
run_publish ''
grep -q -- "--annotation index:org.opencontainers.image.version=v1.2.3" "${docker_log}"
if grep -q -- '--annotation index:index:' "${docker_log}"; then
  echo 'annotation level must not be prefixed twice' >&2
  exit 1
fi
grep -q -- "--tag ${version_tag}" "${docker_log}"
grep -q -- "--tag ${image}:latest" "${docker_log}"
grep -q -- "${image}@sha256:${amd64_digest}" "${docker_log}"
grep -q -- "${image}@sha256:${arm64_digest}" "${docker_log}"
# A single create call carrying both tags and both architecture sources.
[[ $(wc -l <"${docker_log}") == 1 ]]
grep -q 'Published multi-platform index' "${test_root}/stderr"

# The workflow verifies the reference this run published, so the canonical tag
# must be exported as the step output rather than re-derived from its inputs.
GITHUB_OUTPUT=${test_root}/github_output
: >"${GITHUB_OUTPUT}"
run_publish ''
[[ $(<"${GITHUB_OUTPUT}") == "canonical_tag=${version_tag}" ]] || {
  printf 'unexpected canonical_tag output: %s\n' "$(<"${GITHUB_OUTPUT}")" >&2
  exit 1
}
unset GITHUB_OUTPUT

echo 'digest pairing, annotation prefix, tag, and canonical output cases passed'
