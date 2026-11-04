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

abi_hash() {
  jq -S -c '.abi' "$1" | tr -d '\r' | sha256sum | awk '{print $1}'
}

recipe_hash() {
  jq -S -c '.distribution.recipe' "$1" | tr -d '\r' | sha256sum | awk '{print $1}'
}

scripts/plugin-abi.sh validate --candidate

abi_id=$(scripts/plugin-abi.sh render id)
[[ ${abi_id} =~ ^abi-[0-9a-f]{64}$ ]]
recipe_id=$(scripts/plugin-abi.sh render recipe-id)
[[ ${recipe_id} =~ ^recipe-[0-9a-f]{64}$ ]]
recipe_tag=${recipe_id#recipe-}
recipe_tag=${recipe_tag:0:12}

jq -e '.include | map(.platform) == ["linux/amd64", "linux/arm64"]' \
  <<<"$(scripts/plugin-abi.sh render matrix)" >/dev/null

jq -e --arg recipe "${recipe_id}" '
  ."io.rulego.abi.platforms" == "linux/amd64,linux/arm64" and
  ."io.rulego.recipe.id" == $recipe and
  has("io.rulego.abi.platform") == false and
  has("io.rulego.host") == false and
  has("io.rulego.host.tags") == false
' <<<"$(scripts/plugin-abi.sh render metadata plugin-sdk)" >/dev/null

jq -e --arg recipe "${recipe_id}" '
  ."io.rulego.abi.platform" == "linux/arm64" and
  ."io.rulego.server.release" == "v1.0.0" and
  ."io.rulego.recipe.id" == $recipe and
  ."io.rulego.host" == "all-plugin" and
  ."io.rulego.host.tags" == "with_all" and
  ."org.opencontainers.image.version" == "v1.0.0-all-plugin" and
  has("io.rulego.abi.platforms") == false
' <<<"$(scripts/plugin-abi.sh render metadata plugin-runtime arm64 all-plugin)" >/dev/null

jq -e '
  ."io.rulego.host" == "plugin" and
  ."io.rulego.host.tags" == "" and
  ."org.opencontainers.image.version" == "v1.0.0-plugin"
' <<<"$(scripts/plugin-abi.sh render metadata plugin-runtime amd64 plugin)" >/dev/null

expect_failure 'SDK metadata with a host id' \
  scripts/plugin-abi.sh render metadata plugin-sdk amd64 plugin
expect_failure 'runtime metadata without a host id' \
  scripts/plugin-abi.sh render metadata plugin-runtime amd64

sdk_env=$(scripts/plugin-abi.sh render sdk-env amd64)
grep -Fxq 'LINKER_COMMAND=ld' <<<"${sdk_env}"
grep -Fxq 'LINKER_IDENTITY=GNU\ ld' <<<"${sdk_env}"
grep -Fxq 'GOFLAGS=-mod=readonly' <<<"${sdk_env}"
grep -Fxq 'PLUGIN_FLAGS=-trimpath\ -buildvcs=false' <<<"${sdk_env}"
grep -Fxq "ABI_ID=${abi_id}" <<<"${sdk_env}"
grep -Fxq "RECIPE_ID=${recipe_id}" <<<"${sdk_env}"
if grep -Eq '^(SERVER_REVISION|HOST_TAGS|PLUGIN_WORKSPACE)=' <<<"${sdk_env}"; then
  echo 'SDK environment still carries a removed identity variable' >&2
  exit 1
fi

jq -e '.version == "v1.0.0" and .asset.name == "rulego-server-linux-amd64.tar.gz"' \
  <<<"$(scripts/plugin-abi.sh render editor)" >/dev/null

jq -e '
  .runtime_image == "rulego-server" and
  .manifest_path == "/usr/share/rulego/plugin-abi.json" and
  (.hosts | map(.id) == ["plugin", "ai-plugin", "all-plugin"]) and
  (.hosts | map(.tags) == [[], ["with_ai"], ["with_all"]]) and
  (has("runtime_tag_suffix") | not)
' <<<"$(scripts/plugin-abi.sh render ci)" >/dev/null

jq -e --arg recipe "${recipe_id}" '
  .recipe_id == $recipe and
  .manifest_path == "/usr/share/rulego/plugin-abi.json" and
  .rulego_server.release_version == "v1.0.0" and
  .rulego_server.revision == "45d1a6c4e1af594d7319dd11df9fa58bd48fd0e0" and
  .rulego_core.version == "v1.0.0"
' <<<"$(scripts/plugin-abi.sh render build amd64)" >/dev/null

jq -e '.compressed == null and .uncompressed == null' \
  <<<"$(scripts/plugin-abi.sh render size-limit amd64 sdk)" >/dev/null
jq -e 'has("compressed") and has("uncompressed")' \
  <<<"$(scripts/plugin-abi.sh render size-limit arm64 all-plugin)" >/dev/null
expect_failure 'unknown size-limit host' \
  scripts/plugin-abi.sh render size-limit amd64 not-a-host

# The ABI identity covers only .abi. Distribution changes must not perturb it,
# and recipe changes must perturb recipe_id only.
base_abi=$(abi_hash plugin-abi.lock)
base_recipe=$(recipe_hash plugin-abi.lock)

jq '.distribution.hosts[2].tag_suffix = "-all-plugin-next"' plugin-abi.lock >"${test_root}/hosts.json"
[[ $(abi_hash "${test_root}/hosts.json") == "${base_abi}" ]]
[[ $(recipe_hash "${test_root}/hosts.json") == "${base_recipe}" ]]

jq '.distribution.recipe.manifest_path = "/opt/rulego/plugin-abi.json"' plugin-abi.lock >"${test_root}/recipe.json"
[[ $(abi_hash "${test_root}/recipe.json") == "${base_abi}" ]]
[[ $(recipe_hash "${test_root}/recipe.json") != "${base_recipe}" ]]

jq '.distribution.release.sdk_image = "rulego-plugin-sdk-next"' plugin-abi.lock >"${test_root}/release.json"
[[ $(abi_hash "${test_root}/release.json") == "${base_abi}" ]]

jq '.abi.go.version = "1.25.1"' plugin-abi.lock >"${test_root}/abi.json"
[[ $(abi_hash "${test_root}/abi.json") != "${base_abi}" ]]

mutate_and_fail() {
  local description=$1
  local filter=$2
  local target=${test_root}/lock.json
  jq "${filter}" plugin-abi.lock >"${target}"
  expect_failure "${description}" env PLUGIN_ABI_LOCK="${target}" scripts/plugin-abi.sh validate --candidate
}

mutate_and_fail 'stale ABI ID' '.abi.go.version = "1.25.1"'
mutate_and_fail 'stale recipe ID' '.distribution.recipe.manifest_path = "/opt/rulego/plugin-abi.json"'
mutate_and_fail 'missing environment field' 'del(.abi.go.environment.GOENV)'
mutate_and_fail 'unknown environment field' '.abi.go.environment.CC = "gcc"'
mutate_and_fail 'unsupported libc' '.abi.native.libc = "musl"'
mutate_and_fail 'unsupported target' '.abi.go.targets[1].goarch = "riscv64"'
mutate_and_fail 'mutable SDK base' '.abi.native.sdk_base = "golang:1.25.0-bookworm"'
mutate_and_fail 'duplicate target' '.abi.go.targets[1] = .abi.go.targets[0]'
mutate_and_fail 'missing linker command' 'del(.abi.native.toolchains[0].linker_command)'
mutate_and_fail 'compiler identity mismatch' '.abi.native.toolchains[0].cc = "clang"'
mutate_and_fail 'mutable editor source' '.distribution.recipe.editor_payload.asset.sha256 = "latest"'
mutate_and_fail 'editor release differs from host release' '.distribution.recipe.editor_payload.version = "v0.36.0"'
# The core version is either a formal release tag or a pseudo-version that
# carries the pinned revision prefix; anything else must not validate.
mutate_and_fail 'core version is neither a tag nor revision-prefixed' \
  '.abi.rulego_core.version = "v1.0.0-rc1"'
mutate_and_fail 'removed build.host_tags reintroduced' '.abi.build.host_tags = []'
mutate_and_fail 'removed build.plugin_symbol reintroduced' '.abi.build.plugin_symbol = "Plugins"'
mutate_and_fail 'removed build.plugin_workspace reintroduced' \
  '.abi.build.plugin_workspace = "generated-server-and-plugin"'
mutate_and_fail 'removed rulego_server.module reintroduced' \
  '.abi.rulego_server.module = "github.com/rulego/rulego/server"'
mutate_and_fail 'wrong host order' '.distribution.hosts |= reverse'
mutate_and_fail 'wrong host tags' '.distribution.hosts[0].tags = ["with_ai"]'
mutate_and_fail 'unknown runtime size-limit host' \
  '.distribution.release.size_limits.amd64.runtime.extra = {"compressed":null,"uncompressed":null}'
mutate_and_fail 'missing runtime size-limit host' \
  'del(.distribution.release.size_limits.arm64.runtime["all-plugin"])'
mutate_and_fail 'unknown top-level key' '.release = {}'

# A tampered recipe digest that is re-signed into recipe_id must still fail the
# working-tree digest check; only the actual recipe files may satisfy it.
jq '.distribution.recipe.files[0].sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
  plugin-abi.lock >"${test_root}/tampered.json"
tampered_recipe=$(recipe_hash "${test_root}/tampered.json")
jq --arg recipe "recipe-${tampered_recipe}" '.recipe_id = $recipe' \
  "${test_root}/tampered.json" >"${test_root}/tampered-resigned.json"
expect_failure 'tampered recipe file digest' \
  env PLUGIN_ABI_LOCK="${test_root}/tampered-resigned.json" scripts/plugin-abi.sh validate --candidate
grep -Fq 'recipe file digest mismatch' "${test_root}/stderr"

measurement=${test_root}/measurement.json
jq '.distribution.release.state = "measurement" |
  .distribution.release.size_limits |= walk(if type == "number" then null else . end)' \
  plugin-abi.lock >"${measurement}"
PLUGIN_ABI_LOCK=${measurement} scripts/plugin-abi.sh validate --candidate
expect_failure 'measurement lock cannot render public tags' \
  env PLUGIN_ABI_LOCK="${measurement}" scripts/plugin-abi.sh render tags 45d1a6c4e1af

ready=${test_root}/ready.json
jq '.distribution.release.state = "ready" |
  .distribution.release.size_limits |= walk(if type == "number" or . == null then 1 else . end)' \
  plugin-abi.lock >"${ready}"
[[ $(jq -r '.abi_id' "${ready}") == "${abi_id}" ]]
[[ $(jq -r '.recipe_id' "${ready}") == "${recipe_id}" ]]
PLUGIN_ABI_LOCK=${ready} scripts/plugin-abi.sh validate --release
tags=$(PLUGIN_ABI_LOCK=${ready} scripts/plugin-abi.sh render tags 45d1a6c4e1af)
jq -e --arg abi "${abi_id}" --arg recipe "${recipe_tag}" '
  .sdk == ("rulego-plugin-sdk:" + $abi + "-r" + $recipe) and
  (.runtime | map(.host) == ["plugin", "ai-plugin", "all-plugin"]) and
  (.runtime[0].canonical == ("rulego-server:v1.0.0-plugin-r" + $recipe + "-45d1a6c4e1af")) and
  (.runtime[0].alias == "rulego-server:v1.0.0-plugin") and
  (.runtime[1].canonical == ("rulego-server:v1.0.0-ai-plugin-r" + $recipe + "-45d1a6c4e1af")) and
  (.runtime[1].alias == "rulego-server:v1.0.0-ai-plugin") and
  (.runtime[2].canonical == ("rulego-server:v1.0.0-all-plugin-r" + $recipe + "-45d1a6c4e1af")) and
  (.runtime[2].alias == "rulego-server:v1.0.0-all-plugin") and
  (.runtime | all(has("alias")))
' <<<"${tags}" >/dev/null
if grep -Fq 'latest' <<<"${tags}"; then
  echo 'public tags must not contain a mutable latest alias' >&2
  exit 1
fi
expect_failure 'release tag rendering requires a 12-hex revision' \
  env PLUGIN_ABI_LOCK="${ready}" scripts/plugin-abi.sh render tags not-a-revision

null_ready=${test_root}/ready-null.json
jq '.distribution.release.state = "ready"' plugin-abi.lock >"${null_ready}"
expect_failure 'ready lock requires positive size ceilings' \
  env PLUGIN_ABI_LOCK="${null_ready}" scripts/plugin-abi.sh validate --release

echo 'Plugin ABI lock validation and rendering passed'
