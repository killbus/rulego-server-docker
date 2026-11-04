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
sdk_line=$(grep -nF 'sdk_ref=${sdk_repository}@${sdk_child}' "${build}" | cut -d: -f1)
probe_line=$(grep -nF '"${sdk_ref}" . "/output/sdk-probe-${arch}.so"' "${build}" | cut -d: -f1)
sdk_stage_line=$(grep -nF 'imagetools create --tag "${sdk_staging}"' "${build}" | cut -d: -f1)
sdk_stage_readback_line=$(grep -nF 'jq -er '\''.digest'\'' "${work}/sdk-staging.json"' "${build}" | cut -d: -f1)
loop_line=$(grep -nF 'while IFS= read -r host_json' "${build}" | cut -d: -f1)
rootfs_line=$(grep -nF -- '--entrypoint /usr/local/bin/build-plugin-host' "${build}" | cut -d: -f1)
host_tags_line=$(grep -nF -- '--env "HOST_TAGS=${host_tags}"' "${build}" | cut -d: -f1)
candidate_line=$(grep -nF 'candidate_tag=${runtime_repository}:candidate-${host}' "${build}" | cut -d: -f1)
runtime_line=$(grep -nF 'Dockerfile.plugin-runtime' "${build}" | cut -d: -f1)
size_line=$(grep -nF 'runtime_uncompressed=$(docker image inspect' "${build}" | cut -d: -f1)
stage_line=$(grep -nF 'imagetools create --tag "${runtime_staging}"' "${build}" | cut -d: -f1)
((sdk_line < probe_line && probe_line < sdk_stage_line))
((sdk_stage_line < sdk_stage_readback_line && sdk_stage_readback_line < loop_line))
((loop_line < rootfs_line && rootfs_line < host_tags_line && host_tags_line < candidate_line))
((candidate_line < runtime_line && runtime_line < size_line && size_line < stage_line))
grep -Fq 'inspect_native "${sdk_staging}" "${work}/sdk-staging.json"' "${build}"
grep -Fq '[[ $(jq -er '\''.digest'\'' "${work}/sdk-staging.json") == "${sdk_index}" ]]' "${build}"
grep -Fq 'sdk_staging="ghcr.io/${owner}/${sdk_image}:staging-${packaging_revision}-${arch}"' "${build}"

# One SDK image per architecture; one runtime image per host inside the loop.
[[ $(grep -cF 'Dockerfile.plugin-sdk' "${build}") == 1 ]]
[[ $(grep -cF 'Dockerfile.plugin-runtime' "${build}") == 1 ]]
[[ $(grep -cF 'HOST_TAGS' "${build}") == 1 ]]
grep -Fq 'runtime-${host}-evidence.json' "${build}"
grep -Fq 'runtime:$runtime' "${build}"
grep -Fq 'component_expectation()' "${build}"
grep -Fq 'any(.[]; . == "with_ai" or . == "with_all")' "${build}"
grep -Fq "printf 'ai/agent\\n'" "${build}"
grep -Fq "printf 'none\\n'" "${build}"
grep -Fq 'host_component=$(component_expectation "${host_tags_json}")' "${build}"
grep -Fq 'verify-plugin-runtime.sh" load "${runtime_ref}" "${arch}" "${work}/sdk-output/sdk-probe-${arch}.so" "${host_component}"' "${build}"
if grep -Eq "== (ai-plugin|all-plugin)|ai-plugin\\b" "${build}"; then
  echo 'build script derives a component expectation from a host id' >&2
  exit 1
fi
grep -Fq 'any(.type == "ai/agent")' scripts/verify-plugin-runtime.sh
grep -Fq 'any(.type == "myPlugins/upper")' scripts/verify-plugin-runtime.sh

publish=scripts/plugin-abi-publish.sh
grep -Fq 'create_staging_index plugin-sdk' "${publish}"
grep -Fq 'create_staging_index plugin-runtime' "${publish}"
grep -Fq 'verify-plugin-oci.sh" "${sdk_staging_index}" "${staging_index}" release "${host}"' "${publish}"
grep -Fq 'promote_image_alias "${alias}" "${canonical_ref}"' "${publish}"
if grep -Eq 'docker buildx build|docker build[[:space:]]' "${publish}"; then
  echo 'publication rebuilds an image instead of promoting verified evidence' >&2
  exit 1
fi
grep -Fq '.runtime[$host].index_digest' "${publish}"
grep -Fq '.runtime[$host].child_digest' "${publish}"
grep -Fq 'runtime_record' "${publish}"
grep -Fq 'published-sizes-${host}.tsv' "${publish}"
grep -Fq 'published-sizes.tsv' "${publish}"
grep -Fq 'verify-plugin-oci.sh" "${sdk_ref}" "${canonical_ref}" release "${host}"' "${publish}"
grep -Fq 'staging-sizes-${host}.tsv' "${publish}"
grep -Fq 'published size report must contain one SDK row per architecture' "${publish}"

grep -Fq 'render size-limit "${arch}" "${index_host}"' scripts/verify-plugin-oci.sh
grep -Fq 'render metadata "${index_metadata[@]}"' scripts/verify-plugin-oci.sh

grep -Fq 'GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}' .github/workflows/plugin-abi.yml
grep -Fq 'GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}' .github/workflows/plugin-abi-publish.yml

grep -Fq '.index_digest' scripts/plugin-abi-publish.sh
grep -Fq '.child_digest' scripts/plugin-abi-publish.sh
grep -Fq 'publish_immutable_image_tag' scripts/plugin-abi-publish.sh
grep -Fq 'immutable tag already points to a different digest' scripts/lib.sh

echo 'Plugin ABI driver guards and digest flow passed'
