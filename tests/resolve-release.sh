#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/rulego-resolve-test.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

mkdir -p "${test_root}/project/scripts" "${test_root}/bin"
cp "${repository_root}/scripts/lib.sh" "${repository_root}/scripts/resolve-release.sh" \
  "${test_root}/project/scripts/"

jq -n '{tag_name: "v0.37.0", draft: false, prerelease: false}' \
  >"${test_root}/latest.json"
jq -n '{tag_name: "v0.36.0", draft: false, prerelease: false}' \
  >"${test_root}/historical.json"
jq -n '{tag_name: "v0.36.0", draft: false, prerelease: true}' \
  >"${test_root}/prerelease.json"

cat >"${test_root}/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail

output=
headers=
previous=
url=
for argument in "$@"; do
  if [[ $previous == --output ]]; then output=$argument; fi
  if [[ $previous == --dump-header ]]; then headers=$argument; fi
  if [[ $argument == https://* ]]; then url=$argument; fi
  previous=$argument
done
[[ -n $output && -n $headers && -n $url ]]
printf '%s\n' "$url" >>"$MOCK_REQUESTS"
printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"

case $url in
  */releases/latest)
    cp "$MOCK_LATEST_JSON" "$output"
    ;;
  */releases/tags/v0.36.0)
    cp "$MOCK_SELECTED_JSON" "$output"
    ;;
  *)
    printf 'unexpected URL: %s\n' "$url" >&2
    exit 64
    ;;
esac
printf '200'
STUB
chmod +x "${test_root}/bin/curl" "${test_root}/project/scripts/resolve-release.sh"

run_resolver() {
  (
    cd "${test_root}/project"
    PATH="${test_root}/bin:${PATH}" \
      MOCK_LATEST_JSON="${test_root}/latest.json" \
      MOCK_REQUESTS="${test_root}/requests" \
      MOCK_SELECTED_JSON="${MOCK_SELECTED_JSON:-${test_root}/historical.json}" \
      scripts/resolve-release.sh "$@"
  )
}

: >"${test_root}/requests"
resolution=$(run_resolver)
jq -e '
  .version == "v0.37.0"
  and .latest_version == "v0.37.0"
  and .is_latest == true
' <<<"$resolution" >/dev/null
[[ $(wc -l <"${test_root}/requests") == 1 ]]

: >"${test_root}/requests"
resolution=$(run_resolver v0.37.0)
jq -e '.version == "v0.37.0" and .is_latest == true' <<<"$resolution" >/dev/null
[[ $(wc -l <"${test_root}/requests") == 1 ]]

: >"${test_root}/requests"
resolution=$(run_resolver v0.36.0)
jq -e '
  .version == "v0.36.0"
  and .latest_version == "v0.37.0"
  and .is_latest == false
' <<<"$resolution" >/dev/null
[[ $(wc -l <"${test_root}/requests") == 2 ]]

: >"${test_root}/requests"
set +e
MOCK_SELECTED_JSON="${test_root}/prerelease.json" run_resolver v0.36.0 \
  >"${test_root}/prerelease.stdout" 2>"${test_root}/prerelease.stderr"
status=$?
set -e
[[ $status -ne 0 ]]
grep -q 'release is missing, draft, or prerelease' "${test_root}/prerelease.stderr"

: >"${test_root}/requests"
set +e
run_resolver latest >"${test_root}/invalid.stdout" 2>"${test_root}/invalid.stderr"
status=$?
set -e
[[ $status -ne 0 ]]
grep -q 'version must match vMAJOR.MINOR.PATCH' "${test_root}/invalid.stderr"
[[ ! -s ${test_root}/requests ]]

echo 'scheduled, current, historical, prerelease, and invalid release resolution passed'
