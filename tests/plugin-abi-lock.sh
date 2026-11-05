#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"
# shellcheck source=tests/helpers.sh
source "${script_dir}/helpers.sh"

mkdir -p "${repository_root}/tmp"
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

# The file's layout is the output of `jq .`, not a hand-tuned arrangement, and nothing but this check keeps
# it that way. Before this assertion the lock carried 16 compact single-line objects spread over four commits
# -- each editor wrote its own addition in whatever style its tool produced and left its neighbours alone --
# so the first mechanical rewrite of the file moved 102 lines and a rotation done by the documented recipe
# looked like a reformat. Layout carries no contract (every digest here is taken from `jq -S -c` bytes), which
# is exactly why it needed an owner rather than four: with one, the diff of a rotation shows only the values
# that changed, which is the whole reason a rotation is reviewed at all.
if ! cmp -s <(jq . plugin-abi.lock) plugin-abi.lock; then
  echo 'plugin-abi.lock is not the layout jq . prints; reformat it with jq . plugin-abi.lock' >&2
  diff -u plugin-abi.lock <(jq . plugin-abi.lock) | head -20 >&2
  exit 1
fi

abi_id=$(scripts/plugin-abi.sh render id)
[[ ${abi_id} =~ ^abi-[0-9a-f]{64}$ ]]
jq -e '.include | map(.platform) == ["linux/amd64", "linux/arm64"]' \
  <<<"$(scripts/plugin-abi.sh render matrix)" >/dev/null
jq -e '."io.rulego.abi.platforms" == "linux/amd64,linux/arm64" and has("io.rulego.abi.platform") == false' \
  <<<"$(scripts/plugin-abi.sh render metadata plugin-sdk)" >/dev/null
# The rendered annotations may not vary with the commit that packaged the image. A per-commit value
# inside the image config moves the child digest, and the pipeline rests on the child digest being a
# function of the lock alone; `scripts/plugin-abi-build.sh` states that claim and the reproducibility
# recheck enforces it on a real runner. Pinned here so the recipe cannot quietly re-open it.
metadata_sdk=$(scripts/plugin-abi.sh render metadata plugin-sdk amd64)
[[ ${metadata_sdk} == "$(GITHUB_SHA=1111111111111111111111111111111111111111 \
  scripts/plugin-abi.sh render metadata plugin-sdk amd64)" ]] || {
  echo 'rendered image annotations depend on the packaging commit' >&2
  exit 1
}
jq -e --arg revision "$(jq -er '.abi.rulego_server.revision' plugin-abi.lock)" \
  '."org.opencontainers.image.revision" == $revision and
   ."org.opencontainers.image.source" == "https://github.com/rulego/rulego" and
   ."org.opencontainers.image.licenses" == "Apache-2.0"' <<<"${metadata_sdk}" >/dev/null || {
  echo 'image annotations must name the source revision the lock records' >&2
  exit 1
}
jq -e '."io.rulego.abi.platform" == "linux/arm64" and ."io.rulego.server.release" == "v1.0.0" and
  ."org.opencontainers.image.version" == "v1.0.0-plugin" and has("io.rulego.abi.platforms") == false' \
  <<<"$(scripts/plugin-abi.sh render metadata plugin-runtime arm64 plugin)" >/dev/null
grep -Fxq 'LINKER_COMMAND=ld' <(scripts/plugin-abi.sh render sdk-env amd64)
grep -Fxq 'LINKER_IDENTITY=GNU\ ld' <(scripts/plugin-abi.sh render sdk-env amd64)
grep -Fxq 'GOFLAGS=-mod=readonly' <(scripts/plugin-abi.sh render sdk-env amd64)
grep -Fxq 'PLUGIN_FLAGS=-trimpath\ -buildvcs=false' <(scripts/plugin-abi.sh render sdk-env amd64)
jq -e '.version == "v1.0.0" and .asset.name == "rulego-server-linux-amd64.tar.gz"' \
  <<<"$(scripts/plugin-abi.sh render editor)" >/dev/null
jq -e '.runtime_image == "rulego-server" and
  .hosts == [
    {"id":"plugin","tags":[],"tag_suffix":"-plugin"},
    {"id":"ai-plugin","tags":["with_ai"],"tag_suffix":"-ai-plugin"},
    {"id":"all-plugin","tags":["with_all"],"tag_suffix":"-all-plugin"}
  ]' \
  <<<"$(scripts/plugin-abi.sh render ci)" >/dev/null
jq -e '.rulego_server.release_version == "v1.0.0" and
  .rulego_server.revision == "45d1a6c4e1af594d7319dd11df9fa58bd48fd0e0" and
  .rulego_core.version == "v1.0.0"' \
  <<<"$(scripts/plugin-abi.sh render build amd64)" >/dev/null
if scripts/plugin-abi.sh render sdk-env amd64 |
  grep -Eq '^(HOST_ID|HOST_TAGS|HOST_VARIANTS|SERVER_REVISION|PLUGIN_WORKSPACE)='; then
  echo 'sdk-env must not carry distribution identity' >&2
  exit 1
fi
jq -e '."io.rulego.host" == "ai-plugin" and
  ."org.opencontainers.image.version" == "v1.0.0-ai-plugin"' \
  <<<"$(scripts/plugin-abi.sh render metadata plugin-runtime amd64 ai-plugin)" >/dev/null
# The compatibility render is graded against whatever record the lock carries, not against digests copied
# into this file. The record now rotates on its own, so a test that pinned its bytes would go red on every
# honest rotation -- which is the same hand-transcription the rotation gate exists to remove, relocated into
# the suite. What stays pinned here is the projection: which fields the render takes, and how it composes
# the reference for the architecture it was asked about.
jq -e --arg repository "$(jq -er '.distribution.compatibility.previous_sdk.repository' plugin-abi.lock)" \
  --arg abi "$(jq -er '.distribution.compatibility.previous_sdk.abi_id' plugin-abi.lock)" \
  --arg index "$(jq -er '.distribution.compatibility.previous_sdk.index_digest' plugin-abi.lock)" \
  --arg amd64 "$(jq -er '.distribution.compatibility.previous_sdk.children.amd64' plugin-abi.lock)" '
  .abi_id == $abi and .index_digest == $index and .child_digest == $amd64 and
  .reference == ($repository + "@" + $amd64)' \
  <<<"$(scripts/plugin-abi.sh render compatibility-sdk amd64)" >/dev/null
jq -e --arg repository "$(jq -er '.distribution.compatibility.previous_sdk.repository' plugin-abi.lock)" \
  --arg arm64 "$(jq -er '.distribution.compatibility.previous_sdk.children.arm64' plugin-abi.lock)" '
  .child_digest == $arm64 and .reference == ($repository + "@" + $arm64)' \
  <<<"$(scripts/plugin-abi.sh render compatibility-sdk arm64)" >/dev/null

mutate_and_fail() {
  local description=$1
  local filter=$2
  local target=${test_root}/lock.json
  jq "${filter}" plugin-abi.lock >"${target}"
  expect_failure "${description}" env PLUGIN_ABI_LOCK="${target}" scripts/plugin-abi.sh validate --candidate
}

mutate_recipe_and_fail() {
  local description=$1
  local filter=$2
  local target=${test_root}/lock.json
  jq "${filter}" plugin-abi.lock >"${target}"
  refresh_recipe_id "${target}"
  expect_failure "${description}" env PLUGIN_ABI_LOCK="${target}" scripts/plugin-abi.sh validate --candidate
}

mutate_and_fail 'stale ABI ID' '.abi.go.version = "1.25.1"'
mutate_and_fail 'missing environment field' 'del(.abi.go.environment.GOENV)'
mutate_and_fail 'unknown environment field' '.abi.go.environment.CC = "gcc"'
mutate_and_fail 'unsupported libc' '.abi.native.libc = "musl"'
mutate_and_fail 'unsupported target' '.abi.go.targets[1].goarch = "riscv64"'
mutate_and_fail 'mutable SDK base' '.abi.native.sdk_base = "golang:1.25.0-bookworm"'
mutate_and_fail 'invalid host ID' '.distribution.hosts[1].id = "AI_PLUGIN"'
mutate_and_fail 'duplicate host ID' '.distribution.hosts[1].id = .distribution.hosts[0].id'
mutate_and_fail 'invalid host tag suffix' '.distribution.hosts[1].tag_suffix = "ai-plugin"'
mutate_and_fail 'host tag suffix differs from ID' '.distribution.hosts[1].tag_suffix = "-other-plugin"'
mutate_and_fail 'duplicate host tag suffix' '.distribution.hosts[1].tag_suffix = .distribution.hosts[0].tag_suffix'
mutate_and_fail 'unsupported host build tag' '.distribution.hosts[1].tags = ["with_unknown"]'
mutate_and_fail 'standard host is not first' '.distribution.hosts |= reverse'
mutate_and_fail 'standard host has build tags' '.distribution.hosts[0].tags = ["with_ai"]'
mutate_and_fail 'standard host suffix changed' '.distribution.hosts[0].tag_suffix = "-std-plugin"'
mutate_and_fail 'missing compatibility SDK architecture' 'del(.distribution.compatibility.previous_sdk.children.arm64)'
mutate_and_fail 'unknown compatibility SDK architecture' '.distribution.compatibility.previous_sdk.children.riscv64 = .distribution.compatibility.previous_sdk.children.amd64'
mutate_and_fail 'invalid compatibility ABI ID' '.distribution.compatibility.previous_sdk.abi_id = "legacy"'
mutate_and_fail 'compatibility ABI equals current ABI' '.distribution.compatibility.previous_sdk.abi_id = .abi_id'
mutate_and_fail 'invalid compatibility index digest' '.distribution.compatibility.previous_sdk.index_digest = "sha256:invalid"'
mutate_and_fail 'invalid compatibility child digest' '.distribution.compatibility.previous_sdk.children.amd64 = "sha256:invalid"'
mutate_and_fail 'compatibility repository contains tag' '.distribution.compatibility.previous_sdk.repository = "ghcr.io/killbus/rulego-plugin-sdk:latest"'
mutate_and_fail 'compatibility repository contains digest' \
  '.distribution.compatibility.previous_sdk.repository += "@" + .distribution.compatibility.previous_sdk.children.amd64'
mutate_and_fail 'missing host size limit' 'del(.distribution.release.size_limits.amd64.runtime["ai-plugin"])'
mutate_and_fail 'unknown host size limit' '.distribution.release.size_limits.amd64.runtime.extra = {"compressed": null, "uncompressed": null}'
mutate_and_fail 'duplicate target' '.abi.go.targets[1] = .abi.go.targets[0]'
mutate_and_fail 'missing linker command' 'del(.abi.native.toolchains[0].linker_command)'
mutate_and_fail 'compiler identity mismatch' '.abi.native.toolchains[0].cc = "clang"'
mutate_recipe_and_fail 'mutable editor source' '.distribution.recipe.editor_payload.asset.sha256 = "latest"'
mutate_recipe_and_fail 'editor release differs from host release' '.distribution.recipe.editor_payload.version = "v0.36.0"'
# The core version is either a formal release tag or a pseudo-version that
# carries the pinned revision prefix; anything else must not validate.
mutate_and_fail 'core version is neither a tag nor revision-prefixed' \
  '.abi.rulego_core.version = "v1.0.0-rc1"'

measurement=${test_root}/measurement.json
jq '.distribution.release.state = "measurement" |
  (.distribution.release.size_limits[] | .sdk.compressed, .sdk.uncompressed,
    .runtime[].compressed, .runtime[].uncompressed) = null' plugin-abi.lock >"${measurement}"
PLUGIN_ABI_LOCK=${measurement} scripts/plugin-abi.sh validate --candidate
# A fixed 40-character value: the canonical runtime name is per build, so rendering tags at all needs
# one, and a test that left it out would fail for the missing name rather than for the reason it is
# checking. `none` is what a pre-build probe passes and is not a build identity, so it is not used here.
name_revision=$(printf '1%.0s' {1..40})
expect_failure 'measurement lock cannot render public tags' \
  env PLUGIN_ABI_LOCK="${measurement}" PLUGIN_ABI_NAME_REVISION="${name_revision}" \
  scripts/plugin-abi.sh render tags

ready=${test_root}/ready.json
jq '.distribution.release.state = "ready" |
  (.distribution.release.size_limits[] | .sdk.compressed, .sdk.uncompressed,
    .runtime[].compressed, .runtime[].uncompressed) = 1' plugin-abi.lock >"${ready}"
[[ $(jq -r '.abi_id' "${ready}") == "${abi_id}" ]]
PLUGIN_ABI_LOCK=${ready} scripts/plugin-abi.sh validate --release
tags=$(PLUGIN_ABI_LOCK=${ready} PLUGIN_ABI_NAME_REVISION=${name_revision} scripts/plugin-abi.sh render tags)
recipe_tag=$(jq -er '.recipe_id | sub("^recipe-"; "") | .[0:12]' plugin-abi.lock)
jq -e --arg abi_id "${abi_id}" --arg recipe "${recipe_tag}" '
  .sdk == ("rulego-plugin-sdk:" + $abi_id + "-r" + $recipe) and
  .runtime == {
    "plugin":    {canonical:("rulego-server:v1.0.0-plugin-r" + $recipe + "-111111111111"),
                  alias:"rulego-server:v1.0.0-plugin"},
    "ai-plugin": {canonical:("rulego-server:v1.0.0-ai-plugin-r" + $recipe + "-111111111111"),
                  alias:"rulego-server:v1.0.0-ai-plugin"},
    "all-plugin": {canonical:("rulego-server:v1.0.0-all-plugin-r" + $recipe + "-111111111111"),
                   alias:"rulego-server:v1.0.0-all-plugin"}
  }
' <<<"${tags}" >/dev/null

# The SDK name is the identity and carries no build suffix: an SDK is a compile input, so a name that
# moved between builds would leave a plugin built against it pointing at something else.
tags_none=$(PLUGIN_ABI_LOCK=${ready} PLUGIN_ABI_NAME_REVISION=none scripts/plugin-abi.sh render tags --candidate)
jq -e --arg abi_id "${abi_id}" --arg recipe "${recipe_tag}" '
  .sdk == ("rulego-plugin-sdk:" + $abi_id + "-r" + $recipe) and
  (.runtime | to_entries | all(.value.canonical == null)) and
  (.runtime | to_entries | all(.value.alias != null))
' <<<"${tags_none}" >/dev/null

# A revision that is not a full commit is refused rather than abbreviated: `deadbeef` as a prefix is
# also somebody's branch name, and a canonical name minted from a guess could be won twice.
expect_failure 'render tags refuses a partial packaging revision' \
  env PLUGIN_ABI_LOCK="${ready}" PLUGIN_ABI_NAME_REVISION=deadbeef scripts/plugin-abi.sh render tags
expect_failure 'render tags refuses an absent packaging revision' \
  env PLUGIN_ABI_LOCK="${ready}" scripts/plugin-abi.sh render tags

expect_failure 'unknown architecture cannot render compatibility SDK' \
  scripts/plugin-abi.sh render compatibility-sdk riscv64

echo 'Plugin ABI lock validation and rendering passed'
