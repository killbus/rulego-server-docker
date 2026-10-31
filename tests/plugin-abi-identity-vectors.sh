#!/usr/bin/env bash
# Golden identity vectors.
#
# The identity of a Plugin ABI image is `abi-<sha256 of jq -S -c '.abi' | tr -d CR>`. Nothing
# in the suite pinned that as an external fact: `validate` compares the stored `.abi_id`
# against a value recomputed from the same lock, so it is self-referential and cannot notice
# the identity function itself moving. The only literal digest in the suite belongs to a
# superseded contract. This file is the independent oracle: the evaluation domain is frozen as
# bytes, every expected value below is a frozen literal, and each is compared against what the
# production code computes. A vector goes red when the function moves, not when it is re-read.
#
# These are change-detectors, not policy claims. `20cc5f4` deliberately refused to assert
# whether `.abi.build.hosts` belongs to the identity, and this file does not overrule that: it
# records which fields the function reads TODAY, so that changing the domain becomes a
# deliberate edit to a written contract instead of a silent drift in a digest.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

mkdir -p "${repository_root}/tmp"
test_root=$(mktemp -d "${repository_root}/tmp/plugin-abi-identity-vectors.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

canonical_abi_bytes() {
  jq -S -c '.abi' "${1}" | tr -d '\r'
}

canonical_lock_bytes() {
  jq -S -c '.' "${1}" | tr -d '\r'
}

hex_of() {
  sha256sum | awk '{print $1}'
}

abi_of_lock_segment() {
  printf 'abi-%s\n' "$(canonical_abi_bytes "${1}" | hex_of)"
}

lock_digest_of() {
  printf 'sha256:%s\n' "$(canonical_lock_bytes "${1}" | hex_of)"
}

domain=tests/fixtures/plugin-abi-identity/domain.canonical
[[ -f ${domain} ]] || die "the frozen identity domain is missing: ${domain}"

# V0: the shipped lock. The identity and the canonical lock bytes are frozen literals, so a
# change to either cannot pass by re-stamping the value it is checked against. Renaming an
# image, retargeting a runner or filling a ceiling is not something this file can be talked
# into accepting: the bytes below are the contract.
abi_id_v0=abi-7ef7f30db8598b7fdce710287df49bdb047d165749b749fe86c0ef448daf0c3f
lock_digest_v0=sha256:c246fd6cb7f1f36f704cc30391c95f79c678e34d4598164f12b77f9fa565a340

[[ $(abi_of_lock_segment plugin-abi.lock) == "${abi_id_v0}" ]] ||
  die "the identity of the shipped lock moved off its frozen value: $(
    abi_of_lock_segment plugin-abi.lock)"
[[ $(lock_digest_of plugin-abi.lock) == "${lock_digest_v0}" ]] ||
  die "the canonical bytes of the shipped lock moved off their frozen value: $(
    lock_digest_of plugin-abi.lock)"

# The written evaluation domain: the shipped lock must canonicalize to exactly the frozen
# bytes. When this fails, the set of fields the identity reads changed, and every vector below
# has to be re-derived and reviewed as a contract change rather than patched to agree.
cmp -s <(canonical_abi_bytes plugin-abi.lock) "${domain}" ||
  die 'the shipped lock no longer canonicalizes to the frozen identity domain'

# The production path must agree with the independent oracle, otherwise the two have silently
# split and the vectors below would be measuring something nothing else uses.
[[ $(scripts/plugin-abi.sh render id) == "${abi_id_v0}" ]] ||
  die 'scripts/plugin-abi.sh render id disagrees with the frozen identity'
[[ $(scripts/plugin-abi.sh render lock-digest) == "${lock_digest_v0}" ]] ||
  die 'scripts/plugin-abi.sh render lock-digest disagrees with the frozen canonical lock'

# vector <name> <jq filter> <stable|changes> <expected abi_id> <expected lock digest>
#
# The expected values are inputs, never recomputations of themselves, and they are always
# compared for equality: a vector pins the exact digest, so a mutation that lands on any other
# value fails even when it moved. The label then asserts the direction separately against V0.
# Comparing a `changes` vector for inequality against its own expected value would be the same
# self-reference this file exists to remove, because the digest would agree with itself.
vector() {
  local name=$1 filter=$2 expectation=$3 expected_abi=$4 expected_lock=$5 actual_abi actual_lock
  jq "${filter}" plugin-abi.lock >"${test_root}/${name}.json" 2>"${test_root}/${name}.jq" ||
    die "${name}: mutation rejected by jq: $(cat "${test_root}/${name}.jq")"
  jq --arg id "abi-$(canonical_abi_bytes "${test_root}/${name}.json" |
    hex_of)" \
    '.abi_id = $id' "${test_root}/${name}.json" >"${test_root}/${name}.stamped.json"
  PLUGIN_ABI_LOCK=${test_root}/${name}.stamped.json \
    scripts/plugin-abi.sh validate --candidate >"${test_root}/${name}.validate" 2>&1 ||
    die "${name}: not a legal lock: $(tail -n 1 "${test_root}/${name}.validate")"
  actual_abi=$(abi_of_lock_segment "${test_root}/${name}.stamped.json")
  actual_lock=$(lock_digest_of "${test_root}/${name}.stamped.json")
  [[ ${actual_abi} == "${expected_abi}" ]] ||
    die "${name}: the identity moved off its frozen value: ${actual_abi}"
  [[ ${actual_lock} == "${expected_lock}" ]] ||
    die "${name}: the canonical lock bytes moved off their frozen value: ${actual_lock}"
  case ${expectation} in
    stable)
      [[ ${expected_abi} == "${abi_id_v0}" ]] ||
        die "${name}: a stable vector must carry V0's identity"
      # Every stable vector also has to change the canonical bytes, which is the recorded gap
      # below stated structurally: the identity calls these fields policy while the SDK image
      # carries them. If this ever goes red, the manifest stopped depending on the field, and
      # the gap paragraph has to be re-read rather than deleted silently.
      [[ ${expected_lock} != "${lock_digest_v0}" ]] ||
        die "${name}: a policy field left the canonical bytes alone, so the recorded gap
            no longer holds for it and the claim needs re-deriving"
      ;;
    changes)
      [[ ${expected_abi} != "${abi_id_v0}" ]] ||
        die "${name}: a field inside the identity domain left the identity unchanged"
      [[ ${expected_lock} != "${lock_digest_v0}" ]] ||
        die "${name}: a field inside the domain did not change the canonical bytes"
      ;;
    *) die "${name}: unknown expectation" ;;
  esac
}

all_ceilings='{"compressed":1,"uncompressed":1}'

# Stable: packaging policy. Each expected value is V0's identity verbatim, so a future change
# that makes any of these rename an image must re-derive this list in review, not add a field.
vector 'release-state-ready' \
  '.release.state = "ready"
     | .release.size_limits.amd64.sdk = '"${all_ceilings}"'
     | .release.size_limits.amd64.runtime.plugin = '"${all_ceilings}"'
     | .release.size_limits.amd64.runtime["ai-plugin"] = '"${all_ceilings}"'
     | .release.size_limits.arm64.sdk = '"${all_ceilings}"'
     | .release.size_limits.arm64.runtime.plugin = '"${all_ceilings}"'
     | .release.size_limits.arm64.runtime["ai-plugin"] = '"${all_ceilings}"'' \
  stable "${abi_id_v0}" sha256:3270e37519292c8a9c59e895bf5aed1a10b20e2df5c64f58cd4b584d566689b8
vector 'amd64-runner-label' '.release.ci.runners.amd64 = "ubuntu-24.04-alt"' \
  stable "${abi_id_v0}" sha256:d62e44a15e27da97c72e5e24599dca603b02dfa9075575e41b3a32696133b441
vector 'sdk-repository-name' '.release.sdk_image = "rulego-plugin-sdk-alt"' \
  stable "${abi_id_v0}" sha256:7301d94ad8f7170f37436ab657cae2cc67d986926bff89e0a1ada30da7feb1f7
vector 'runtime-repository-name' '.release.runtime_image = "rulego-server-alt"' \
  stable "${abi_id_v0}" sha256:9c631e0ba8ed52f148b19c24321211e933d79a041440c58af042260ecd75adc3
vector 'embedded-manifest-path' '.release.manifest_path = "/other/plugin-abi.json"' \
  stable "${abi_id_v0}" sha256:ffdb96acef9dc8eec6048e6409b0603d12de7b6e02b51a63bc3912aed64e4a31
vector 'reproducible-epoch' '.release.reproducible_epoch = 1700000001' \
  stable "${abi_id_v0}" sha256:9de23fc0db58df74ddf96aa98d96e8b862f2c2a83d89a21f96faa9079b4afc39
vector 'editor-asset-digest' \
  '.release.editor_payload.asset.sha256 =
     "0000000000000000000000000000000000000000000000000000000000000001"' \
  stable "${abi_id_v0}" sha256:6d547fb3e018b560f544f8e74e4a71f52abcb82f9250f9573a90c99960cab7aa
vector 'previous-sdk-index-digest' \
  '.compatibility.previous_sdk.index_digest =
     "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  stable "${abi_id_v0}" sha256:1a00a935ec83f9bc3332256b147d28e7046419e05430eff0eabe4832c6f36e14

# Changes: fields inside the domain. Both the identity and the canonical bytes are frozen, so
# the direction and the magnitude are each asserted separately.
vector 'go-version' '.abi.go.version = "1.25.1"' \
  changes abi-61db21edbe2336b29f5404472627702e1315aa13c03936dc6989fb848aa38f78 \
    sha256:bd39e80a46598be47ad5d053a7e4f2ad08e31e01bf12a53f4337b7d8d456c1fc
vector 'module-graph-list-digest' \
  '.abi.module_graph.list_sha256 =
     "0000000000000000000000000000000000000000000000000000000000000001"' \
  changes abi-f421c028b44afbc9997db8336bc56fb14581efd69157986e87fd646dfdb9612b \
    sha256:6c7a4cf1a3653b02315db7038859d33e4faddc67f68b8323592b16ef2e9d4537
# A new host must carry a ceiling entry because the schema keys ceilings off the host list.
# Copying the sibling's value instead of writing nulls keeps this vector legal in either
# release state: null under measurement, positive under ready. Hardcoding null here made it a
# measurement-only test, so filling the ceilings reddened it for a reason unrelated to what the
# vector claims to measure.
vector 'host-list-grows' \
  '.abi.build.hosts += [{"id":"all-plugin","tags":["with_ai","with_all"],
      "tag_suffix":"-all-plugin"}]
     | .release.size_limits.amd64.runtime["all-plugin"] =
         .release.size_limits.amd64.runtime.plugin
     | .release.size_limits.arm64.runtime["all-plugin"] =
         .release.size_limits.arm64.runtime.plugin' \
  changes abi-22d172256d0e4b3850ab70c893aa319cfe97743e5977ac8f015882607e98d1bd \
    sha256:c78fddb8ca5cd20d7d3d03bf508b827cff449176d1c7bc3e448f31d1191ffdf6
vector 'host-tags-cleared' '.abi.build.hosts[1].tags = []' \
  changes abi-635ad61cd1a27fb3974754b88b1ae7d626dcc415a952fd13b60339fca5b1fd3b \
    sha256:ec31b6bc5c5c7893982ff4f6c0a744ca18ac4a5e4ee4d3fcbc366c67a53f467f

# The gap this file exists to keep visible rather than to freeze as correct.
#
# `20cc5f4` argued that packaging fields must not rename an image because they are not compiled
# into one. Measured, that is not the whole truth: `render manifest` canonicalizes the WHOLE
# lock, that manifest is copied into the SDK image, `render sdk-env` writes LOCK_DIGEST into
# /opt/rulego/build.env, and the SDK's own RUN asserts sha256(/abi-manifest.json) ==
# LOCK_DIGEST. So a policy-only edit leaves the identity alone while changing the bytes of the
# image that identity names, and two locks that differ only in ceilings would claim one ABI.
# The epoch vector above already carries both halves: same identity, different canonical bytes.
# Asserted explicitly here so the mismatch is stated, and so closing the gap by deriving the
# manifest from the identity domain flips this red and gets reviewed instead of passing unseen.
[[ $(jq -r '.abi_id' "${test_root}/reproducible-epoch.stamped.json") == "${abi_id_v0}" ]] ||
  die 'the epoch is supposed to leave the identity alone'
[[ $(lock_digest_of "${test_root}/reproducible-epoch.stamped.json") != "${lock_digest_v0}" ]] ||
  die 'a policy-only edit must change the canonical bytes the SDK image carries'
grep -Fq 'LOCK_DIGEST' <(scripts/plugin-abi.sh render sdk-env amd64) ||
  die 'the SDK build environment no longer carries the lock digest this gap depends on'
grep -Fq 'sha256sum /abi-manifest.json' Dockerfile.plugin-sdk ||
  die 'the SDK recipe no longer asserts the manifest against the lock digest'

echo 'Plugin ABI golden identity vectors passed: 12 vectors and 1 recorded gap.'
