#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

for test_script in \
  "${script_dir}/fetch-release-failure.sh" \
  "${script_dir}/fetch-release-success.sh" \
  "${script_dir}/fetch-plugin-editor.sh" \
  "${script_dir}/lib-plugin-helpers.sh" \
  "${script_dir}/repository-contract.sh" \
  "${script_dir}/plugin-abi-lock.sh" \
  "${script_dir}/plugin-abi-identity-scope.sh" \
  "${script_dir}/plugin-abi-identity-vectors.sh" \
  "${script_dir}/plugin-abi-drivers.sh" \
  "${script_dir}/plugin-build-helper.sh" \
  "${script_dir}/plugin-image-contract.sh" \
  "${script_dir}/plugin-publication-policy.sh" \
  "${script_dir}/prepare-plugin-abi.sh" \
  "${script_dir}/resolve-release.sh" \
  "${script_dir}/publish-index.sh" \
  "${script_dir}/retry-and-manifest.sh" \
  "${script_dir}/verify-published-failures.sh"; do
  "${test_script}"
done
