#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/rulego-fetch-test.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

mkdir -p "${test_root}/project/scripts" "${test_root}/bin"
cp "${repository_root}/scripts/lib.sh" "${repository_root}/scripts/fetch-release.sh" \
  "${test_root}/project/scripts/"

printf 'deliberately corrupted archive\n' >"${test_root}/archive.tar.gz"
write_release_json() {
  local digest=$1
  jq -n --arg digest "sha256:${digest}" '{
    tag_name: "v0.37.0",
    draft: false,
    prerelease: false,
    assets: [{
      name: "rulego-server-linux-amd64.tar.gz",
      browser_download_url: "https://github.com/rulego/rulego/releases/download/v0.37.0/rulego-server-linux-amd64.tar.gz",
      digest: $digest
    }]
  }' >"${test_root}/release.json"
}

write_release_json "$(printf '0%.0s' {1..64})"

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
[[ -n $output ]]
[[ -n $headers ]]
[[ -n $url ]]
printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
if [[ $url == https://api.github.com/* ]]; then
  cp "$MOCK_RELEASE_JSON" "$output"
else
  if [[ -n ${DOWNLOAD_CALLED:-} ]]; then : >"$DOWNLOAD_CALLED"; fi
  cp "$MOCK_ARCHIVE" "$output"
fi
printf '200'
STUB

cat >"${test_root}/bin/tar" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
: >"$TAR_CALLED"
exit 88
STUB
chmod +x "${test_root}/bin/curl" "${test_root}/bin/tar" \
  "${test_root}/project/scripts/fetch-release.sh"

set +e
(
  cd "${test_root}/project"
  PATH="${test_root}/bin:${PATH}" \
    MOCK_ARCHIVE="${test_root}/archive.tar.gz" \
    MOCK_RELEASE_JSON="${test_root}/release.json" \
    TAR_CALLED="${test_root}/tar-called" \
    scripts/fetch-release.sh v0.37.0 standard
) >"${test_root}/stdout" 2>"${test_root}/stderr"
status=$?
set -e

[[ $status -ne 0 ]] || {
  echo 'expected corrupt archive verification to fail' >&2
  exit 1
}
grep -q 'archive checksum mismatch' "${test_root}/stderr" || {
  cat "${test_root}/stderr" >&2
  echo 'checksum failure was not reported' >&2
  exit 1
}
[[ ! -e ${test_root}/tar-called ]] || {
  echo 'tar was invoked before archive checksum verification completed' >&2
  exit 1
}
[[ ! -e ${test_root}/project/build ]] || {
  echo 'a build directory was published after checksum failure' >&2
  exit 1
}

python3 - "${test_root}/unsafe.tar.gz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], mode="w:gz") as archive:
    content = b"must never escape the extraction root\n"
    member = tarfile.TarInfo(name="../outside")
    member.size = len(content)
    archive.addfile(member, io.BytesIO(content))
PY
unsafe_sha=$(sha256sum "${test_root}/unsafe.tar.gz" | awk '{print $1}')
write_release_json "${unsafe_sha}"

set +e
(
  cd "${test_root}/project"
  PATH="${test_root}/bin:${PATH}" \
    MOCK_ARCHIVE="${test_root}/unsafe.tar.gz" \
    MOCK_RELEASE_JSON="${test_root}/release.json" \
    TAR_CALLED="${test_root}/tar-called" \
    scripts/fetch-release.sh v0.37.0 standard
) >"${test_root}/unsafe.stdout" 2>"${test_root}/unsafe.stderr"
unsafe_status=$?
set -e

[[ $unsafe_status -ne 0 ]]
grep -q 'unsafe member found' "${test_root}/unsafe.stderr"
[[ ! -e ${test_root}/tar-called ]]
[[ ! -e ${test_root}/project/build ]]

jq '.assets[0].digest = null' "${test_root}/release.json" >"${test_root}/missing-digest.json"
set +e
(
  cd "${test_root}/project"
  PATH="${test_root}/bin:${PATH}" \
    DOWNLOAD_CALLED="${test_root}/download-called" \
    MOCK_ARCHIVE="${test_root}/unsafe.tar.gz" \
    MOCK_RELEASE_JSON="${test_root}/missing-digest.json" \
    TAR_CALLED="${test_root}/tar-called" \
    scripts/fetch-release.sh v0.37.0 standard
) >"${test_root}/missing.stdout" 2>"${test_root}/missing.stderr"
missing_status=$?
set -e

[[ $missing_status -ne 0 ]]
grep -q 'has no valid SHA-256 digest' "${test_root}/missing.stderr"
[[ ! -e ${test_root}/download-called ]]
[[ ! -e ${test_root}/tar-called ]]
[[ ! -e ${test_root}/project/build ]]

echo 'missing digest, corrupt archive, and unsafe archive failures passed'
