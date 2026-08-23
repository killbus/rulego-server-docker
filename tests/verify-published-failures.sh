#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/rulego-published-test.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

mkdir -p \
  "${test_root}/project/scripts" \
  "${test_root}/project/build/amd64" \
  "${test_root}/project/build/arm64" \
  "${test_root}/bin"
cp "${repository_root}/scripts/lib.sh" "${repository_root}/scripts/verify-published.sh" \
  "${test_root}/project/scripts/"
printf 'v0.37.0\n' >"${test_root}/project/build/version"
expected_sha=$(printf 'expected binary' | sha256sum | awk '{print $1}')
printf '%s\n' "$expected_sha" >"${test_root}/project/build/amd64/rulego-server.sha256"
printf '%s\n' "$expected_sha" >"${test_root}/project/build/arm64/rulego-server.sha256"

cat >"${test_root}/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $1 == buildx && $2 == imagetools && $3 == inspect ]]; then
  if [[ $MOCK_MODE == missing ]]; then
    cat <<'JSON'
{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","manifests":[{"platform":{"os":"linux","architecture":"amd64"}}]}
JSON
  else
    cat <<'JSON'
{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64","variant":"v8"}}]}
JSON
  fi
elif [[ $1 == pull ]]; then
  :
elif [[ $1 == create ]]; then
  printf 'mock-container-id\n'
elif [[ $1 == cp ]]; then
  printf 'tampered binary' >"$3"
elif [[ $1 == rm ]]; then
  :
else
  printf 'unexpected docker invocation:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 64
fi
STUB

cat >"${test_root}/bin/sleep" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
:
STUB
chmod +x "${test_root}/bin/docker" "${test_root}/bin/sleep" \
  "${test_root}/project/scripts/verify-published.sh"

run_failure_case() {
  local mode=$1
  local expected_message=$2
  set +e
  (
    cd "${test_root}/project"
    PATH="${test_root}/bin:${PATH}" MOCK_MODE="${mode}" \
      REGISTRY_RETRY_ATTEMPTS=2 REGISTRY_RETRY_INITIAL_DELAY=1 \
      REGISTRY_RETRY_MAX_DELAY=1 \
      scripts/verify-published.sh registry.invalid/example:test
  ) >"${test_root}/${mode}.stdout" 2>"${test_root}/${mode}.stderr"
  status=$?
  set -e

  [[ $status -ne 0 ]]
  grep -q "${expected_message}" "${test_root}/${mode}.stderr"
}

run_failure_case missing 'could not inspect published image after bounded retries'
run_failure_case mismatch 'published image checksum mismatch for amd64'

echo 'missing-platform and executable-mismatch failures passed'
