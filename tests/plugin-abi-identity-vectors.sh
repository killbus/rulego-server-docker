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
lock_digest_v0=sha256:d1e14c9683a2dff600f896ac788dead0ff437fb0f80459474ba9288b4b340059

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
  stable "${abi_id_v0}" sha256:107df7815c3ce4c763ded2dd9f95fad6f736873e5c91ace47b6e67c7910623d4
vector 'sdk-repository-name' '.release.sdk_image = "rulego-plugin-sdk-alt"' \
  stable "${abi_id_v0}" sha256:057615b92f1b992a738620064d2729616925b5bb5aa58d079ba92ebf84b66cee
vector 'runtime-repository-name' '.release.runtime_image = "rulego-server-alt"' \
  stable "${abi_id_v0}" sha256:a6602d2fd321ef804bf7bbe022defe783c0c25de6958da7d0d4af75755228217
vector 'embedded-manifest-path' '.release.manifest_path = "/other/plugin-abi.json"' \
  stable "${abi_id_v0}" sha256:4efc39b808b57772281ae70b9aa1d5fa2bbe9736219e5d9a37987083d1078deb
vector 'reproducible-epoch' '.release.reproducible_epoch = 1700000001' \
  stable "${abi_id_v0}" sha256:8d14333a827a1c08411166ba5a26f3b0e1d6a346317a4b4b9ad326b672160328
vector 'editor-asset-digest' \
  '.release.editor_payload.asset.sha256 =
     "0000000000000000000000000000000000000000000000000000000000000001"' \
  stable "${abi_id_v0}" sha256:f97f66a9b0b07708ad834cb612c67ae1b62c716d59a7ff039c39874790942a8a
vector 'previous-sdk-index-digest' \
  '.compatibility.previous_sdk.index_digest =
     "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  stable "${abi_id_v0}" sha256:8a0ff9cbf53a2468ab847260245ea6d7de7b2f6015656e5d82126b02c2a53371

# Changes: fields inside the domain. Both the identity and the canonical bytes are frozen, so
# the direction and the magnitude are each asserted separately.
vector 'go-version' '.abi.go.version = "1.25.1"' \
  changes abi-61db21edbe2336b29f5404472627702e1315aa13c03936dc6989fb848aa38f78 \
    sha256:e204fa4f2f03a7f00589f5818ccd9ccf9afe4014b84b6025aed901a02efc8ad3
vector 'module-graph-list-digest' \
  '.abi.module_graph.list_sha256 =
     "0000000000000000000000000000000000000000000000000000000000000001"' \
  changes abi-f421c028b44afbc9997db8336bc56fb14581efd69157986e87fd646dfdb9612b \
    sha256:e997e50a6b6a8cdef13f604e2893e384975606547ee443ea6371353dee2fb53d
vector 'host-list-grows' \
  '.abi.build.hosts += [{"id":"all-plugin","tags":["with_ai","with_all"],
      "tag_suffix":"-all-plugin"}]
     | .release.size_limits.amd64.runtime["all-plugin"] =
         {"compressed":null,"uncompressed":null}
     | .release.size_limits.arm64.runtime["all-plugin"] =
         {"compressed":null,"uncompressed":null}' \
  changes abi-22d172256d0e4b3850ab70c893aa319cfe97743e5977ac8f015882607e98d1bd \
    sha256:f23e644b17ecde120f30d7b8c799d2e52f4846193e3bb5a0d7ef3d11dcefb312
vector 'host-tags-cleared' '.abi.build.hosts[1].tags = []' \
  changes abi-635ad61cd1a27fb3974754b88b1ae7d626dcc415a952fd13b60339fca5b1fd3b \
    sha256:eee57fd88d5a6ccbd9cf5f37071874e6031da1ffcb143796593e64838e1b7bf6

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
