#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/rulego-fetch-success.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

mkdir -p "${test_root}/project/scripts" "${test_root}/assets" "${test_root}/bin"
cp "${repository_root}/scripts/lib.sh" "${repository_root}/scripts/fetch-release.sh" \
  "${test_root}/project/scripts/"

make_asset() {
  local prefix=$1
  local architecture=$2
  local payload=${test_root}/payload-${prefix}-${architecture}
  local asset=${prefix}-linux-${architecture}.tar.gz

  mkdir -p "${payload}/editor"
  printf '%s %s executable\n' "$prefix" "$architecture" \
    >"${payload}/${prefix}-linux-${architecture}"
  printf 'config for %s %s\n' "$prefix" "$architecture" >"${payload}/config.conf"
  printf '{"nodes":[]}\n' >"${payload}/node_pool.json"
  printf '<html>%s %s</html>\n' "$prefix" "$architecture" >"${payload}/editor/index.html"
  tar -czf "${test_root}/assets/${asset}" -C "$payload" .
}

for prefix in rulego-server rulego-server-all; do
  for architecture in amd64 arm64; do
    make_asset "$prefix" "$architecture"
  done
done

jq -n --arg assets_dir "${test_root}/assets" '
  {
    tag_name: "v0.37.0",
    draft: false,
    prerelease: false,
    assets: [
      "rulego-server-linux-amd64.tar.gz",
      "rulego-server-linux-arm64.tar.gz",
      "rulego-server-all-linux-amd64.tar.gz",
      "rulego-server-all-linux-arm64.tar.gz"
    ] | map({
      name: .,
      browser_download_url: ("https://github.com/rulego/rulego/releases/download/v0.37.0/" + .),
      digest: ("sha256:" + .)
    })
  }
' >"${test_root}/release-template.json"

jq --arg assets_dir "${test_root}/assets" '
  .assets |= map(.digest = ("sha256:" + .name))
' "${test_root}/release-template.json" >"${test_root}/release-names.json"

{
  printf '{"tag_name":"v0.37.0","draft":false,"prerelease":false,"assets":['
  separator=
  for asset_path in "${test_root}"/assets/*.tar.gz; do
    asset_name=${asset_path##*/}
    digest=$(sha256sum "$asset_path" | awk '{print $1}')
    printf '%s' "$separator"
    jq -cn --arg name "$asset_name" --arg digest "sha256:${digest}" '{
      name: $name,
      browser_download_url: ("https://github.com/rulego/rulego/releases/download/v0.37.0/" + $name),
      digest: $digest
    }'
    separator=,
  done
  printf ']}\n'
} >"${test_root}/release.json"

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
printf 'HTTP/1.1 200 OK\r\n\r\n' >"$headers"
if [[ $url == https://api.github.com/* ]]; then
  cp "$MOCK_RELEASE_JSON" "$output"
else
  cp "$MOCK_ASSET_DIR/${url##*/}" "$output"
fi
printf '200'
STUB
chmod +x "${test_root}/bin/curl" "${test_root}/project/scripts/fetch-release.sh"

for variant in standard all; do
  if [[ $variant == standard ]]; then prefix=rulego-server; else prefix=rulego-server-all; fi
  (
    cd "${test_root}/project"
    PATH="${test_root}/bin:${PATH}" \
      MOCK_ASSET_DIR="${test_root}/assets" \
      MOCK_RELEASE_JSON="${test_root}/release.json" \
      scripts/fetch-release.sh v0.37.0 "$variant"
  ) >"${test_root}/${variant}.stdout" 2>"${test_root}/${variant}.stderr"

  [[ $(<"${test_root}/project/build/version") == v0.37.0 ]]
  [[ $(<"${test_root}/project/build/variant") == "$variant" ]]
  for architecture in amd64 arm64; do
    rootfs=${test_root}/project/build/${architecture}/rootfs
    printf '%s %s executable\n' "$prefix" "$architecture" \
      | cmp - "${rootfs}/rulego-server"
    [[ -f ${rootfs}/config.conf ]]
    [[ -f ${rootfs}/node_pool.json ]]
    [[ -f ${rootfs}/editor/index.html ]]
    [[ -d ${rootfs}/data ]]
    expected_sha=$(sha256sum "${rootfs}/rulego-server" | awk '{print $1}')
    [[ $(<"${test_root}/project/build/${architecture}/rulego-server.sha256") == "$expected_sha" ]]
    awk -F '\t' -v architecture="$architecture" -v asset="${prefix}-linux-${architecture}.tar.gz" \
      '$1 == architecture && $2 == asset && $3 ~ /^[0-9a-f]{64}$/ && $4 ~ /^[0-9a-f]{64}$/ { found = 1 }
       END { exit !found }' "${test_root}/project/build/release-manifest.tsv"
  done
done

echo 'standard and all release preparation succeeded for both architectures'
