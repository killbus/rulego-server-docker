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
abi_id_v0=abi-b54242128c9bef3b3f839e8a7cba390111c5cd1768158a465716e2cabe55a01f
lock_digest_v0=sha256:e628ccc9d149eab5d28e0ef9d6c49ecc50b9ff5aa5a39771df7cb7b6630deb24

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
  stable "${abi_id_v0}" sha256:7f04998e0fd3c51b51015e1873594e1b5fb9d8cd3074b0e5f210c8710539d74b
vector 'amd64-runner-label' '.release.ci.runners.amd64 = "ubuntu-24.04-alt"' \
  stable "${abi_id_v0}" sha256:c3f929558c6fe5e134e968546c6c8ca5c0a698c47d8bbf6f7dff54982bbabdd1
vector 'sdk-repository-name' '.release.sdk_image = "rulego-plugin-sdk-alt"' \
  stable "${abi_id_v0}" sha256:704fe4f230d2c17082d47953709bf971da45f4d09c0b0dfe408d2f26eb74be34
vector 'runtime-repository-name' '.release.runtime_image = "rulego-server-alt"' \
  stable "${abi_id_v0}" sha256:ea6c75b728804b1bfee3dde7fb4163cfc77aa984be018964fca457a056a3a362
vector 'embedded-manifest-path' '.release.manifest_path = "/other/plugin-abi.json"' \
  stable "${abi_id_v0}" sha256:e9622ec92b21f815039060462072bde178e85b4bd83af7567ca37db90c75621c
vector 'reproducible-epoch' '.release.reproducible_epoch = 1700000001' \
  stable "${abi_id_v0}" sha256:cccf3cd5d36d80a03ace23976d059b50f5d1714db7fc0bc65224f18a49046811
vector 'editor-asset-digest' \
  '.release.editor_payload.asset.sha256 =
     "0000000000000000000000000000000000000000000000000000000000000001"' \
  stable "${abi_id_v0}" sha256:b71c9019185fe1f96040375b6c39400761f16c701d31408786fe9985b4604f35
vector 'previous-sdk-index-digest' \
  '.compatibility.previous_sdk.index_digest =
     "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  stable "${abi_id_v0}" sha256:d9134c82ddcd7a19100bd4d6b0db88087ab15d4659ce34dad890f6d32983ddb7

# Changes: fields inside the domain. Both the identity and the canonical bytes are frozen, so
# the direction and the magnitude are each asserted separately.
vector 'go-version' '.abi.go.version = "1.25.1"' \
  changes abi-3eb7ff4bbbd0b3df6d56f716e9b297b625f3fc230c969b0dedce11582ab1663a \
    sha256:bc18bc325c549be19ffcfd4e65c040ee799e369c37905c190bc5fd98421e4b53
vector 'module-graph-list-digest' \
  '.abi.module_graph.list_sha256 =
     "0000000000000000000000000000000000000000000000000000000000000001"' \
  changes abi-ccd9f2425825113d2d5d5abd90638dba143d9e71735d657fe05588b0bc2a79fe \
    sha256:9daa306ba0476f9765ae30c6870846a2f8fd0a8e91d3ed326fb38097f0722965
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
  changes abi-47d47a97dada15437d43400e2efdb3d10225c2cb8a5d59aa4808cc5ca1ace23c \
    sha256:9b856d8514bff55856f571215d0382f39b9169e36f702affdf11e10f4db27154
vector 'host-tags-cleared' '.abi.build.hosts[1].tags = []' \
  changes abi-45e475c913be11e2f55dfc55f8bcbff850badc7885d294fc48987f014e70de57 \
    sha256:38876ee6e655f833dd73737e035d68633bcc9fbec5a78011ed8902cce771386d
# The recipe is inside the domain. A packaging generation that moves must move the identity, because
# that is the mechanism by which new bytes arrive under a name nobody has spent: measured on the live
# registry, `abi-f972e691` and `abi-78737478` are canonical tags held by artifacts this recipe cannot
# reproduce, and without this field the only remedy left to the gate was to wait for an upstream
# release version.
vector 'packaging-generation' '.abi.packaging.version = "3"' \
  changes abi-af0e7765afa339934f9a8bc41b71bbe45176c48f173f5909732867c48fbd6bee \
    sha256:6fe67dfa5c99795c369e269ca74b73f34b0048344fad932c4feb768d7c5536b8

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

echo 'Plugin ABI golden identity vectors passed: 13 vectors and 1 recorded gap.'
