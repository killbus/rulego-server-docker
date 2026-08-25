#!/usr/bin/env bash
# shellcheck disable=SC2016

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

test_root=$(mktemp -d "${repository_root}/tmp/plugin-abi-drivers.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

expect_failure() {
  local expected=$1
  shift
  if "$@" >"${test_root}/stdout" 2>"${test_root}/stderr"; then
    printf 'expected command to fail: %s\n' "$*" >&2
    exit 1
  fi
  grep -Fq "${expected}" "${test_root}/stderr"
}

expect_failure 'run only in GitHub Actions' env -u GITHUB_ACTIONS scripts/plugin-abi-build.sh amd64
expect_failure 'unsupported build architecture' env GITHUB_ACTIONS=true scripts/plugin-abi-build.sh riscv64
expect_failure 'runs only in GitHub Actions' env -u GITHUB_ACTIONS scripts/plugin-abi-publish.sh "${test_root}"
expect_failure 'requires PLUGIN_ABI_PUBLISH=true' env GITHUB_ACTIONS=true scripts/plugin-abi-publish.sh "${test_root}"

build=scripts/plugin-abi-build.sh
sdk_line=$(grep -n 'sdk_ref=${sdk_repository}@${sdk_child}' "${build}" | cut -d: -f1)
probe_line=$(grep -n '"${sdk_ref}" . "/output/sdk-probe-${arch}.so"' "${build}" | cut -d: -f1)
rootfs_line=$(grep -n -- '--entrypoint /usr/local/bin/build-plugin-host' "${build}" | cut -d: -f1)
runtime_line=$(grep -n 'Dockerfile.plugin-runtime' "${build}" | cut -d: -f1)
stage_line=$(grep -n 'imagetools create --tag "${sdk_staging}"' "${build}" | cut -d: -f1)
size_line=$(grep -n 'runtime_uncompressed=$(docker image inspect' "${build}" | cut -d: -f1)
((sdk_line < probe_line && probe_line < rootfs_line && rootfs_line < runtime_line && runtime_line < size_line && size_line < stage_line))

grep -Fq 'GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}' .github/workflows/plugin-abi.yml
grep -Fq 'GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}' .github/workflows/plugin-abi-publish.yml

grep -Fq '.index_digest' scripts/plugin-abi-publish.sh
grep -Fq '.child_digest' scripts/plugin-abi-publish.sh
grep -Fq 'publish_immutable_image_tag' scripts/plugin-abi-publish.sh
grep -Fq 'immutable tag already points to a different digest' scripts/lib.sh

echo 'Plugin ABI driver guards and digest flow passed'
