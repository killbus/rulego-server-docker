#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

for test_script in \
  "${script_dir}/fetch-release-failure.sh" \
  "${script_dir}/fetch-release-success.sh" \
  "${script_dir}/repository-contract.sh" \
  "${script_dir}/resolve-release.sh" \
  "${script_dir}/retry-and-manifest.sh" \
  "${script_dir}/verify-published-failures.sh"; do
  "${test_script}"
done
