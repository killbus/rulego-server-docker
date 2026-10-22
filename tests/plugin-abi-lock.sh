#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

test_root=$(mktemp -d "${repository_root}/tmp/plugin-abi-lock.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

expect_failure() {
  local description=$1
  shift
  if "$@" >"${test_root}/stdout" 2>"${test_root}/stderr"; then
    printf 'expected failure: %s\n' "${description}" >&2
    exit 1
  fi
}

scripts/plugin-abi.sh validate --candidate

abi_id=$(scripts/plugin-abi.sh render id)
[[ ${abi_id} =~ ^abi-[0-9a-f]{64}$ ]]
jq -e '.include | map(.platform) == ["linux/amd64", "linux/arm64"]' \
  <<<"$(scripts/plugin-abi.sh render matrix)" >/dev/null
jq -e '."io.rulego.abi.platforms" == "linux/amd64,linux/arm64" and has("io.rulego.abi.platform") == false' \
  <<<"$(scripts/plugin-abi.sh render metadata plugin-sdk)" >/dev/null
jq -e '."io.rulego.abi.platform" == "linux/arm64" and ."io.rulego.server.release" == "v1.0.0" and
  ."org.opencontainers.image.version" == "v1.0.0-plugin" and has("io.rulego.abi.platforms") == false' \
  <<<"$(scripts/plugin-abi.sh render metadata plugin-runtime arm64)" >/dev/null
grep -Fxq 'LINKER_COMMAND=ld' <(scripts/plugin-abi.sh render sdk-env amd64)
grep -Fxq 'LINKER_IDENTITY=GNU\ ld' <(scripts/plugin-abi.sh render sdk-env amd64)
grep -Fxq 'GOFLAGS=-mod=readonly' <(scripts/plugin-abi.sh render sdk-env amd64)
grep -Fxq 'PLUGIN_FLAGS=-trimpath\ -buildvcs=false' <(scripts/plugin-abi.sh render sdk-env amd64)
jq -e '.version == "v1.0.0" and .asset.name == "rulego-server-linux-amd64.tar.gz"' \
  <<<"$(scripts/plugin-abi.sh render editor)" >/dev/null
jq -e '.runtime_image == "rulego-server" and .runtime_tag_suffix == "-plugin"' \
  <<<"$(scripts/plugin-abi.sh render ci)" >/dev/null
jq -e '.rulego_server.release_version == "v1.0.0" and
  .rulego_server.revision == "45d1a6c4e1af594d7319dd11df9fa58bd48fd0e0" and
  .rulego_core.version == "v1.0.0"' \
  <<<"$(scripts/plugin-abi.sh render build amd64)" >/dev/null

mutate_and_fail() {
  local description=$1
  local filter=$2
  local target=${test_root}/lock.json
  jq "${filter}" plugin-abi.lock >"${target}"
  expect_failure "${description}" env PLUGIN_ABI_LOCK="${target}" scripts/plugin-abi.sh validate --candidate
}

mutate_and_fail 'stale ABI ID' '.abi.go.version = "1.25.1"'
mutate_and_fail 'missing environment field' 'del(.abi.go.environment.GOENV)'
mutate_and_fail 'unknown environment field' '.abi.go.environment.CC = "gcc"'
mutate_and_fail 'unsupported libc' '.abi.native.libc = "musl"'
mutate_and_fail 'unsupported target' '.abi.go.targets[1].goarch = "riscv64"'
mutate_and_fail 'mutable SDK base' '.abi.native.sdk_base = "golang:1.25.0-bookworm"'
mutate_and_fail 'invalid runtime tag suffix' '.release.runtime_tag_suffix = "plugin"'
mutate_and_fail 'duplicate target' '.abi.go.targets[1] = .abi.go.targets[0]'
mutate_and_fail 'missing linker command' 'del(.abi.native.toolchains[0].linker_command)'
mutate_and_fail 'compiler identity mismatch' '.abi.native.toolchains[0].cc = "clang"'
mutate_and_fail 'mutable editor source' '.release.editor_payload.asset.sha256 = "latest"'
mutate_and_fail 'editor release differs from host release' '.release.editor_payload.version = "v0.36.0"'
# The core version is either a formal release tag or a pseudo-version that
# carries the pinned revision prefix; anything else must not validate.
mutate_and_fail 'core version is neither a tag nor revision-prefixed' \
  '.abi.rulego_core.version = "v1.0.0-rc1"'

measurement=${test_root}/measurement.json
jq '.release.state = "measurement" | .release.size_limits[][][] = null' plugin-abi.lock >"${measurement}"
PLUGIN_ABI_LOCK=${measurement} scripts/plugin-abi.sh validate --candidate
expect_failure 'measurement lock cannot render public tags' \
  env PLUGIN_ABI_LOCK="${measurement}" scripts/plugin-abi.sh render tags

ready=${test_root}/ready.json
jq '.release.state = "ready" | .release.size_limits[][][] = 1' plugin-abi.lock >"${ready}"
[[ $(jq -r '.abi_id' "${ready}") == "${abi_id}" ]]
PLUGIN_ABI_LOCK=${ready} scripts/plugin-abi.sh validate --release
tags=$(PLUGIN_ABI_LOCK=${ready} scripts/plugin-abi.sh render tags)
jq -e --arg abi_id "${abi_id}" '
  .sdk == ("rulego-plugin-sdk:" + $abi_id) and
  .runtime == "rulego-server:v1.0.0-plugin"
' <<<"${tags}" >/dev/null

echo 'Plugin ABI lock validation and rendering passed'
