#!/usr/bin/env bash
# Identity-scope property test.
#
# The ABI identity is the digest of the `.abi` segment only. A field that does not
# decide a produced artifact must not move it; a field that does must. Each probe
# re-stamps `.abi_id` from the mutated `.abi` first, so the staleness check inside
# `validate` cannot mask whether the identity function itself moved.
#
# `.abi.build.hosts` is deliberately NOT asserted here. Whether the host list
# belongs to the identity is an open contract question, and asserting either way
# would freeze an unmade decision into the schema.

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

scripts/plugin-abi.sh validate --candidate
baseline=$(canonical_abi_id plugin-abi.lock)
[[ ${baseline} == "$(scripts/plugin-abi.sh render id)" ]] ||
  die 'lock ships a stale abi_id; the probe cannot isolate the identity function'

# probe <description> <jq filter> <stable|changes>
probe() {
  local description=$1 filter=$2 expectation=$3 actual
  jq "${filter}" plugin-abi.lock >"${test_root}/mutated.json" 2>"${test_root}/jq" ||
    die "probe rejected by jq: ${description}: $(cat "${test_root}/jq")"
  # Re-stamp so a validation failure can only mean the schema itself objects.
  jq --arg id "$(canonical_abi_id "${test_root}/mutated.json")" '.abi_id = $id' \
    "${test_root}/mutated.json" >"${test_root}/stamped.json"
  PLUGIN_ABI_LOCK=${test_root}/stamped.json scripts/plugin-abi.sh validate --candidate \
    >"${test_root}/validate" 2>&1 ||
    die "probe is not a legal mutation: ${description}: $(tail -n 1 "${test_root}/validate")"
  actual=$(canonical_abi_id "${test_root}/stamped.json")
  case ${expectation} in
    stable)
      [[ ${actual} == "${baseline}" ]] ||
        die "policy field moved the identity: ${description}"
      ;;
    changes)
      [[ ${actual} != "${baseline}" ]] ||
        die "artifact field left the identity stale: ${description}"
      ;;
    *) die "unknown expectation: ${expectation}" ;;
  esac
}

asset_sha=0000000000000000000000000000000000000000000000000000000000000001
revision=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# Repository names, runners, ceilings and the previous release are packaging policy:
# none of them is compiled into an image, so none of them may rename one.
probe 'editor asset digest' ".release.editor_payload.asset.sha256 = \"${asset_sha}\"" stable
probe 'editor asset name' '.release.editor_payload.asset.name = "other.tar.gz"' stable
probe 'SDK image repository name' '.release.sdk_image = "rulego-plugin-sdk-alt"' stable
probe 'runtime image repository name' '.release.runtime_image = "rulego-server-alt"' stable
probe 'embedded manifest path' '.release.manifest_path = "/other/plugin-abi.json"' stable
probe 'amd64 runner label' '.release.ci.runners.amd64 = "ubuntu-24.04-alt"' stable
probe 'previous SDK repository' \
  '.compatibility.previous_sdk.repository = "ghcr.io/killbus/rulego-plugin-sdk-alt"' stable

# Toolchain, module graph and pinned revisions are compiled into the artifacts:
# leaving the identity unchanged here would let two different builds claim one ABI.
probe 'Go version' '.abi.go.version = "1.25.1"' changes
probe 'libc minimum version' '.abi.native.minimum_version = "2.35"' changes
probe 'module graph list digest' ".abi.module_graph.list_sha256 = \"${asset_sha}\"" changes
probe 'server revision' ".abi.rulego_server.revision = \"${revision}\"" changes
probe 'core revision' ".abi.rulego_core.revision = \"${revision}\"" changes

printf 'Plugin ABI identity scope: 12 probes held.\n'
