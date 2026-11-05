#!/usr/bin/env bash
# Identity-scope property test.
#
# Two content identities exist, and each has its own domain:
#   abi_id    = sha256(canonical .abi)
#   recipe_id = sha256(canonical .distribution.recipe)
#
# Distribution policy -- hosts, compatibility, release state, image names, runners and ceilings --
# may move neither identity. Recipe inputs -- manifest path, reproducible epoch, editor payload and
# recipe file pins -- move recipe_id only. ABI inputs move abi_id only. Each probe re-stamps both
# identities from the mutated lock first, so the staleness check inside `validate` cannot mask
# whether an identity function itself moved.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

mkdir -p "${repository_root}/tmp"
test_root=$(mktemp -d "${repository_root}/tmp/plugin-abi-identity-scope.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

canonical_abi_id() {
  jq -S -c '.abi' "${1}" | tr -d '\r' | sha256sum | awk '{print "abi-"$1}'
}

canonical_recipe_id() {
  jq -S -c '.distribution.recipe' "${1}" | tr -d '\r' | sha256sum | awk '{print "recipe-"$1}'
}

canonical_document() {
  jq -S -c '{abi_id, abi}' "${1}" | tr -d '\r'
}

scripts/plugin-abi.sh validate --candidate
baseline_abi=$(canonical_abi_id plugin-abi.lock)
baseline_recipe=$(canonical_recipe_id plugin-abi.lock)
[[ ${baseline_abi} == "$(scripts/plugin-abi.sh render id)" ]] ||
  die 'lock ships a stale abi_id; the probe cannot isolate the identity function'
[[ ${baseline_recipe} == "$(scripts/plugin-abi.sh render recipe-id)" ]] ||
  die 'lock ships a stale recipe_id; the probe cannot isolate the recipe function'
document_baseline=$(canonical_document plugin-abi.lock)
[[ ${document_baseline} == "$(scripts/plugin-abi.sh render manifest)" ]] ||
  die 'the embedded document no longer equals what this probe recomputes from the lock'

# probe <description> <jq filter> <abi stable|changes> <recipe stable|changes>
probe() {
  local description=$1 filter=$2 abi_expectation=$3 recipe_expectation=$4
  local actual_abi actual_recipe actual_document
  jq "${filter}" plugin-abi.lock >"${test_root}/mutated.json" 2>"${test_root}/jq" ||
    die "probe rejected by jq: ${description}: $(cat "${test_root}/jq")"
  jq --arg id "$(canonical_abi_id "${test_root}/mutated.json")" \
    --arg recipe "$(canonical_recipe_id "${test_root}/mutated.json")" \
    '.abi_id = $id | .recipe_id = $recipe' \
    "${test_root}/mutated.json" >"${test_root}/stamped.json"
  PLUGIN_ABI_LOCK=${test_root}/stamped.json scripts/plugin-abi.sh validate --candidate \
    >"${test_root}/validate" 2>&1 ||
    die "probe is not a legal mutation: ${description}: $(tail -n 1 "${test_root}/validate")"
  actual_abi=$(canonical_abi_id "${test_root}/stamped.json")
  actual_recipe=$(canonical_recipe_id "${test_root}/stamped.json")
  actual_document=$(canonical_document "${test_root}/stamped.json")
  case ${abi_expectation} in
    stable)
      [[ ${actual_abi} == "${baseline_abi}" ]] ||
        die "distribution or recipe field moved the ABI identity: ${description}"
      [[ ${actual_document} == "${document_baseline}" ]] ||
        die "distribution or recipe field moved the document inside the images: ${description}"
      ;;
    changes)
      [[ ${actual_abi} != "${baseline_abi}" ]] ||
        die "ABI field left the identity stale: ${description}"
      [[ ${actual_document} != "${document_baseline}" ]] ||
        die "ABI field left the document inside the images unchanged: ${description}"
      ;;
    *) die "unknown ABI expectation: ${abi_expectation}" ;;
  esac
  case ${recipe_expectation} in
    stable)
      [[ ${actual_recipe} == "${baseline_recipe}" ]] ||
        die "non-recipe field moved the recipe identity: ${description}"
      ;;
    changes)
      [[ ${actual_recipe} != "${baseline_recipe}" ]] ||
        die "recipe field left the recipe identity stale: ${description}"
      ;;
    *) die "unknown recipe expectation: ${recipe_expectation}" ;;
  esac
}

asset_sha=0000000000000000000000000000000000000000000000000000000000000001
revision=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# Byte-production inputs: the ABI equivalence class does not change, but the recipe that produces
# the bytes does, so the recipe-qualified tag must move.
probe 'editor asset digest' \
  ".distribution.recipe.editor_payload.asset.sha256 = \"${asset_sha}\"" stable changes
probe 'editor asset name' \
  '.distribution.recipe.editor_payload.asset.name = "other.tar.gz"' stable changes
probe 'embedded manifest path' \
  '.distribution.recipe.manifest_path = "/other/plugin-abi.json"' stable changes
probe 'reproducible epoch' \
  '.distribution.recipe.reproducible_epoch = 1700000001' stable changes

# Distribution policy: neither identity may move.
probe 'SDK image repository name' '.distribution.release.sdk_image = "rulego-plugin-sdk-alt"' stable stable
probe 'runtime image repository name' '.distribution.release.runtime_image = "rulego-server-alt"' stable stable
probe 'amd64 runner label' '.distribution.release.ci.runners.amd64 = "ubuntu-24.04-alt"' stable stable
probe 'previous SDK repository' \
  '.distribution.compatibility.previous_sdk.repository = "ghcr.io/killbus/rulego-plugin-sdk-alt"' stable stable
probe 'previous SDK index digest' \
  ".distribution.compatibility.previous_sdk.index_digest = \"sha256:${asset_sha}\"" stable stable

# Toolchain, module graph and pinned revisions are compiled into the artifacts: leaving the ABI
# identity unchanged here would let two different builds claim one ABI.
probe 'Go version' '.abi.go.version = "1.25.1"' changes stable
probe 'libc minimum version' '.abi.native.minimum_version = "2.35"' changes stable
probe 'module graph list digest' ".abi.module_graph.list_sha256 = \"${asset_sha}\"" changes stable
probe 'server revision' ".abi.rulego_server.revision = \"${revision}\"" changes stable
probe 'core revision' ".abi.rulego_core.revision = \"${revision}\"" changes stable

printf 'Plugin ABI identity scope: 14 probes held.\n'
