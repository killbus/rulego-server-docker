#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

[[ $# == 1 ]] || die 'usage: scripts/fetch-plugin-editor.sh <output-directory>'
output=$1
editor=$("${script_dir}/plugin-abi.sh" render editor)
repository=$(jq -er '.repository' <<<"${editor}")
version=$(jq -er '.version' <<<"${editor}")
asset=$(jq -er '.asset.name' <<<"${editor}")
expected_sha=$(jq -er '.asset.sha256' <<<"${editor}")
repository_path=${repository#https://github.com/}

require_command jq python3 tar
mkdir -p "${repository_root}/tmp" "$(dirname -- "${output}")"
work=$(mktemp -d "${repository_root}/tmp/plugin-editor.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

github_api_get "${work}/release.json" "https://api.github.com/repos/${repository_path}/releases/tags/${version}"
jq -e --arg version "${version}" '.tag_name == $version and .draft == false and .prerelease == false' \
  "${work}/release.json" >/dev/null || die "editor source is not the locked stable release: ${version}"
asset_record=$(jq -ec --arg name "${asset}" \
  '[.assets[] | select(.name == $name)] | if length == 1 then .[0] else error("editor asset must exist exactly once") end' \
  "${work}/release.json") || die "editor asset must exist exactly once: ${asset}"
url=$(jq -er '.browser_download_url' <<<"${asset_record}")
api_digest=$(jq -er '.digest' <<<"${asset_record}")
[[ ${api_digest} == "sha256:${expected_sha}" ]] || die "editor API digest mismatch: ${asset}"
[[ ${url} == "${repository}/releases/download/${version}/${asset}" ]] || die "unexpected editor asset URL: ${url}"

archive=${work}/${asset}
download_get "${archive}" "${url}"
[[ $(sha256_file "${archive}") == "${expected_sha}" ]] || die "editor archive digest mismatch: ${asset}"
python3 - "${archive}" <<'PY'
import pathlib
import sys
import tarfile

with tarfile.open(sys.argv[1], "r:gz") as archive:
    names = set()
    for member in archive.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if not member.name or path.is_absolute() or "\\" in member.name or ".." in path.parts:
            raise SystemExit(f"unsafe archive member: {member.name}")
        if member.name in names:
            raise SystemExit(f"duplicate archive member: {member.name}")
        names.add(member.name)
        if not (member.isfile() or member.isdir()):
            raise SystemExit(f"unsupported archive member type: {member.name}")
    if "editor/index.html" not in names:
        raise SystemExit("editor/index.html is missing from locked archive")
PY

mkdir -p "${work}/payload"
tar -C "${work}/payload" --no-same-owner --no-same-permissions -xzf "${archive}" editor
[[ ! -e ${output} ]] || die "editor output already exists: ${output}"
mv -- "${work}/payload/editor" "${output}"
