#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

usage() {
  printf 'Usage: %s <vMAJOR.MINOR.PATCH> <standard|all>\n' "${0##*/}" >&2
}

if (($# != 2)); then
  usage
  exit 2
fi

version=$1
variant=$2
validate_version "${version}"

case ${variant} in
  standard)
    asset_prefix=rulego-server
    ;;
  all)
    asset_prefix=rulego-server-all
    ;;
  *)
    die "variant must be 'standard' or 'all': ${variant}"
    ;;
esac

require_command awk chmod curl dirname jq mkdir mv python3 rm sha256sum tar

download_dir=$(mktemp -d "${TMPDIR:-/tmp}/rulego-download.XXXXXX")
staging_dir=$(mktemp -d "${repository_root}/.build-staging.XXXXXX")
cleanup() {
  rm -rf -- "${download_dir}"
  if [[ -n ${staging_dir:-} && -d ${staging_dir} ]]; then
    rm -rf -- "${staging_dir}"
  fi
}
trap cleanup EXIT

release_json=${download_dir}/release.json
github_api_get \
  "${release_json}" \
  "https://api.github.com/repos/rulego/rulego/releases/tags/${version}"

jq -e --arg version "${version}" '
  .tag_name == $version
  and .draft == false
  and .prerelease == false
' "${release_json}" >/dev/null || die "release is missing, draft, or prerelease: ${version}"

printf 'architecture\tasset\tarchive_sha256\tbinary_sha256\n' >"${staging_dir}/release-manifest.tsv"
printf '%s\n' "${version}" >"${staging_dir}/version"
printf '%s\n' "${variant}" >"${staging_dir}/variant"

for architecture in amd64 arm64; do
  asset_name=${asset_prefix}-linux-${architecture}.tar.gz
  binary_name=${asset_prefix}-linux-${architecture}
  asset_record=$(jq -er --arg asset_name "${asset_name}" '
    [.assets[] | select(.name == $asset_name)] as $matches
    | if ($matches | length) != 1 then
        error("expected exactly one matching release asset")
      else
        [$matches[0].browser_download_url, $matches[0].digest] | @tsv
      end
  ' "${release_json}") || die "could not resolve exactly one asset: ${asset_name}"

  IFS=$'\t' read -r asset_url published_digest <<<"${asset_record}"
  [[ ${asset_url} == "https://github.com/rulego/rulego/releases/download/${version}/${asset_name}" ]] \
    || die "unexpected release asset URL: ${asset_url}"
  [[ ${published_digest} =~ ^sha256:([0-9a-f]{64})$ ]] \
    || die "release asset has no valid SHA-256 digest: ${asset_name}"
  expected_archive_sha=${BASH_REMATCH[1]}

  archive_path=${download_dir}/${asset_name}
  log "Downloading ${asset_name}"
  download_get "${archive_path}" "${asset_url}"

  actual_archive_sha=$(sha256_file "${archive_path}")
  [[ ${actual_archive_sha} == "${expected_archive_sha}" ]] \
    || die "archive checksum mismatch for ${asset_name}: expected ${expected_archive_sha}, got ${actual_archive_sha}"
  log "Verified official archive SHA-256 for ${asset_name}: ${actual_archive_sha}"

  # Validate names and member types before tar writes anything. Links, devices,
  # FIFOs, duplicate paths, absolute paths, and parent traversal are rejected.
  python3 - "${archive_path}" <<'PY' || die "unsafe member found in ${asset_name}"
import pathlib
import sys
import tarfile

seen = set()
with tarfile.open(sys.argv[1], mode="r:gz") as archive:
    for member in archive.getmembers():
        name = member.name
        path = pathlib.PurePosixPath(name)
        if not name or name.startswith("/") or "\\" in name or ".." in path.parts:
            raise SystemExit(f"unsafe archive path: {name!r}")
        normalized = str(path)
        if normalized in seen:
            raise SystemExit(f"duplicate archive path: {name!r}")
        seen.add(normalized)
        if not (member.isfile() or member.isdir()):
            raise SystemExit(f"unsupported archive member type: {name!r}")
PY

  rootfs_dir=${staging_dir}/${architecture}/rootfs
  mkdir -p "${rootfs_dir}"
  tar --extract --gzip --file "${archive_path}" \
    --directory "${rootfs_dir}" \
    --no-same-owner \
    --no-same-permissions

  [[ -f ${rootfs_dir}/${binary_name} ]] || die "missing executable in ${asset_name}: ${binary_name}"
  [[ -f ${rootfs_dir}/config.conf ]] || die "missing config.conf in ${asset_name}"
  [[ -f ${rootfs_dir}/node_pool.json ]] || die "missing node_pool.json in ${asset_name}"
  [[ -f ${rootfs_dir}/editor/index.html ]] || die "missing editor/index.html in ${asset_name}"

  mv -- "${rootfs_dir}/${binary_name}" "${rootfs_dir}/rulego-server"
  chmod 0755 "${rootfs_dir}/rulego-server"
  mkdir -p "${rootfs_dir}/data"
  binary_sha=$(sha256_file "${rootfs_dir}/rulego-server")
  printf '%s\n' "${binary_sha}" >"${staging_dir}/${architecture}/rulego-server.sha256"
  printf '%s\t%s\t%s\t%s\n' \
    "${architecture}" "${asset_name}" "${actual_archive_sha}" "${binary_sha}" \
    >>"${staging_dir}/release-manifest.tsv"
done

build_dir=${repository_root}/build
rm -rf -- "${build_dir}"
mv -- "${staging_dir}" "${build_dir}"
staging_dir=

log "Prepared ${variant} ${version} build context at ${build_dir}"
