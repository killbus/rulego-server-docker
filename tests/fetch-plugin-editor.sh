#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

test_root=$(mktemp -d "${repository_root}/tmp/fetch-plugin-editor.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/payload/editor"
printf '<html>editor</html>\n' >"${test_root}/payload/editor/index.html"
printf 'not copied\n' >"${test_root}/payload/rulego-server-linux-amd64"
tar -C "${test_root}/payload" -czf "${test_root}/editor.tar.gz" editor rulego-server-linux-amd64
archive_sha=$(sha256sum "${test_root}/editor.tar.gz" | awk '{print $1}')
jq --arg sha "${archive_sha}" '.release.editor_payload.asset.sha256 = $sha' \
  plugin-abi.lock >"${test_root}/lock.json"

cat >"${test_root}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=
previous=
for argument in "$@"; do
  if [[ ${previous} == --output ]]; then output=${argument}; fi
  previous=${argument}
done
url=${*: -1}
if [[ ${url} == */releases/tags/v1.0.0 ]]; then
  jq -n --arg sha "${MOCK_ARCHIVE_SHA}" '{tag_name:"v1.0.0",draft:false,prerelease:false,assets:[{
    name:"rulego-server-linux-amd64.tar.gz",
    digest:("sha256:" + $sha),
    browser_download_url:"https://github.com/rulego/rulego/releases/download/v1.0.0/rulego-server-linux-amd64.tar.gz"
  }]}' >"${output}"
else
  cp -- "${MOCK_ARCHIVE}" "${output}"
fi
printf '200'
EOF
chmod +x "${test_root}/bin/curl"

run_fetch() {
  env PATH="${test_root}/bin:${PATH}" \
    MOCK_ARCHIVE="${MOCK_ARCHIVE:-${test_root}/editor.tar.gz}" \
    MOCK_ARCHIVE_SHA="${archive_sha}" \
    PLUGIN_ABI_LOCK="${test_root}/lock.json" \
    scripts/fetch-plugin-editor.sh "${test_root}/output"
}

run_fetch
[[ -f ${test_root}/output/index.html ]]
[[ ! -e ${test_root}/output/rulego-server-linux-amd64 ]]

printf 'corrupt\n' >"${test_root}/corrupt.tar.gz"
if MOCK_ARCHIVE="${test_root}/corrupt.tar.gz" run_fetch >"${test_root}/stdout" 2>"${test_root}/stderr"; then
  echo 'expected corrupt editor archive to fail' >&2
  exit 1
fi
grep -Fq 'editor archive digest mismatch' "${test_root}/stderr"

echo 'Plugin editor payload verification passed'
