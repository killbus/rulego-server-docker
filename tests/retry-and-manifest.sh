#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031 # Each case intentionally isolates its mock environment.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/rulego-retry-test.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

mkdir -p "${test_root}/bin"

cat >"${test_root}/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail

output=
headers=
previous=
for argument in "$@"; do
  if [[ $previous == --output ]]; then output=$argument; fi
  if [[ $previous == --dump-header ]]; then headers=$argument; fi
  previous=$argument
done
[[ -n $output && -n $headers ]]

count=0
if [[ -f $MOCK_STATE ]]; then count=$(<"$MOCK_STATE"); fi
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_STATE"
response=$(cut -d, -f"$count" <<<"$MOCK_SEQUENCE")

case $response in
  exit92)
    printf 'partial' >"$output"
    printf '000'
    exit 92
    ;;
  403-rate)
    printf 'HTTP/1.1 403 Forbidden\r\nX-RateLimit-Remaining: 0\r\n\r\n' >"$headers"
    printf 'rate limited' >"$output"
    printf '403'
    ;;
  403-secondary)
    printf 'HTTP/1.1 403 Forbidden\r\nX-RateLimit-Remaining: 42\r\n\r\n' >"$headers"
    printf '{"message":"You have exceeded a secondary rate limit"}' >"$output"
    printf '403'
    ;;
  200)
    printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
    cp "$MOCK_BODY" "$output"
    printf '200'
    ;;
  *)
    printf 'HTTP/1.1 %s Error\r\n\r\n' "$response" >"$headers"
    printf 'request failed' >"$output"
    printf '%s' "$response"
    ;;
esac
STUB

cat >"${test_root}/bin/sleep" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$1" >>"$MOCK_SLEEPS"
STUB

cat >"${test_root}/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail

count=0
if [[ -f $MOCK_STATE ]]; then count=$(<"$MOCK_STATE"); fi
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_STATE"
response=$(cut -d, -f"$count" <<<"$MOCK_SEQUENCE")

case $response in
  error)
    echo 'unexpected EOF while reading registry response' >&2
    exit 1
    ;;
  notfound)
    echo 'manifest unknown: manifest not found' >&2
    exit 1
    ;;
  plain-notfound)
    echo 'ERROR: registry.invalid/example:test: not found' >&2
    exit 1
    ;;
  invalid)
    printf '{"truncated":'
    ;;
  missing)
    cat <<'JSON'
{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","manifests":[{"platform":{"os":"linux","architecture":"amd64"}}]}
JSON
    ;;
  complete)
    cat <<'JSON'
{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64","variant":"v8"}}]}
JSON
    ;;
  *)
    echo "unknown mock response: $response" >&2
    exit 64
    ;;
esac
STUB

chmod +x "${test_root}/bin/curl" "${test_root}/bin/docker" "${test_root}/bin/sleep"
printf 'trusted response body\n' >"${test_root}/body"

run_http_case() {
  local sequence=$1
  local expected_count=$2
  local expected_status=$3
  : >"${test_root}/sleeps"
  rm -f -- "${test_root}/state" "${test_root}/output"

  set +e
  # Variables in the command string intentionally expand in the child shell.
  # shellcheck disable=SC2016
  env \
    PATH="${test_root}/bin:${PATH}" \
    MOCK_BODY="${test_root}/body" \
    MOCK_SEQUENCE="${sequence}" \
    MOCK_SLEEPS="${test_root}/sleeps" \
    MOCK_STATE="${test_root}/state" \
    HTTP_RETRY_ATTEMPTS=5 \
    HTTP_RETRY_INITIAL_DELAY=1 \
    HTTP_RETRY_MAX_DELAY=2 \
    LIB_PATH="${repository_root}/scripts/lib.sh" \
    OUTPUT_PATH="${test_root}/output" \
    bash -c 'source "$LIB_PATH"; http_get_with_retry "$OUTPUT_PATH" 5 "https://example.invalid/test"' \
    >"${test_root}/stdout" 2>"${test_root}/stderr"
  status=$?
  set -e

  [[ $status == "$expected_status" ]]
  [[ $(<"${test_root}/state") == "$expected_count" ]]
}

run_http_case 'exit92,429,503,200' 4 0
cmp "${test_root}/body" "${test_root}/output"
[[ $(paste -sd, "${test_root}/sleeps") == '1,2,2' ]]

run_http_case '403-rate,200' 2 0
[[ $(paste -sd, "${test_root}/sleeps") == '1' ]]

run_http_case '403-secondary,200' 2 0
[[ $(paste -sd, "${test_root}/sleeps") == '1' ]]

run_http_case '404' 1 1
[[ ! -s ${test_root}/sleeps ]]

run_manifest_case() {
  local sequence=$1
  local wait_for_presence=$2
  local expected_count=$3
  local expected_status=$4
  rm -f -- "${test_root}/state"
  : >"${test_root}/sleeps"

  set +e
  # Variables in the command string intentionally expand in the child shell.
  # shellcheck disable=SC2016
  output=$(env \
    PATH="${test_root}/bin:${PATH}" \
    MOCK_SEQUENCE="${sequence}" \
    MOCK_SLEEPS="${test_root}/sleeps" \
    MOCK_STATE="${test_root}/state" \
    REGISTRY_RETRY_ATTEMPTS=3 \
    REGISTRY_RETRY_INITIAL_DELAY=1 \
    REGISTRY_RETRY_MAX_DELAY=2 \
    LIB_PATH="${repository_root}/scripts/lib.sh" \
    WAIT_FOR_PRESENCE="${wait_for_presence}" \
    bash -c 'source "$LIB_PATH"; image_manifest_digest "registry.invalid/example:test" "$WAIT_FOR_PRESENCE"' \
    2>"${test_root}/stderr")
  status=$?
  set -e

  [[ $status == "$expected_status" ]]
  [[ $(<"${test_root}/state") == "$expected_count" ]]
}

run_manifest_case 'error,complete' false 2 0
[[ $output == sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]]
run_manifest_case 'invalid,complete' false 2 0
run_manifest_case 'missing' false 1 1
run_manifest_case 'plain-notfound' false 1 1
run_manifest_case 'notfound,complete' true 2 0

echo 'bounded network retries and complete manifest validation passed'
