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

# The bytes the images actually carry. Before this file had a name for it, the only "canonical
# bytes" were the whole lock, so a policy edit and an identity edit looked the same from here and
# the gap could only be described in prose. `canonical_manifest` is what the SDK and both runtimes
# embed, so this is the digest that a published name owes its content.
canonical_manifest_bytes() {
  jq -S -c '{abi_id, abi}' "${1}" | tr -d '\r'
}

manifest_digest_of() {
  printf 'sha256:%s\n' "$(canonical_manifest_bytes "${1}" | hex_of)"
}

domain=tests/fixtures/plugin-abi-identity/domain.canonical
[[ -f ${domain} ]] || die "the frozen identity domain is missing: ${domain}"

# V0: the shipped lock. The identity and the canonical lock bytes are frozen literals, so a
# change to either cannot pass by re-stamping the value it is checked against. Renaming an
# image, retargeting a runner or filling a ceiling is not something this file can be talked
# into accepting: the bytes below are the contract.
abi_id_v0=abi-af0e7765afa339934f9a8bc41b71bbe45176c48f173f5909732867c48fbd6bee
lock_digest_v0=sha256:b730e945ede0e1a6eeb16cae274a0eb11b5ee0bab94a21c4df4758d204ffaefd
manifest_digest_v0=sha256:94228ff6c6e3059a692fc186d5d695cf824c3f9c10d0d3a771343764fb6268a1

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
#
# Three digests are pinned per vector, because three different things can move: `abi_id` (the
# identity), the canonical lock bytes (a file in this repository) and the canonical manifest bytes
# (the document both published images carry). Only the first two used to be the same question; the
# third is what made the gap below visible as a number. The manifest digests live in a sibling
# fixture rather than inline, because they are the one column a policy edit is NOT expected to
# move: a table with one row per vector makes a missing or stale row a failure of its own.
manifest_vectors=tests/fixtures/plugin-abi-identity/manifest-digests.tsv
[[ -f ${manifest_vectors} ]] || die "the frozen manifest digests are missing: ${manifest_vectors}"

expected_manifest_of() {
  awk -F '\t' -v name="${1}" '$1 == name { print $2; exit }' "${manifest_vectors}"
}

vector() {
  local name=$1 filter=$2 expectation=$3 expected_abi=$4 expected_lock=$5
  local expected_manifest
  local actual_abi actual_lock actual_manifest
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
  actual_manifest=$(manifest_digest_of "${test_root}/${name}.stamped.json")
  # Derive mode prints what the production code computes and asserts nothing, which is the only
  # honest way to regenerate the frozen values: a re-derivation that also judged them would grade
  # its own homework. Used by hand when the identity function or the lock moves on purpose.
  if [[ ${PLUGIN_ABI_DERIVE:-0} == 1 ]]; then
    printf 'VECTOR\t%s\t%s\t%s\t%s\n' "${name}" "${actual_abi}" "${actual_lock}" "${actual_manifest}"
    return 0
  fi
  expected_manifest=$(expected_manifest_of "${name}")
  [[ -n ${expected_manifest} ]] ||
    die "${name}: no frozen manifest digest for this vector; the table and the list have drifted"
  [[ ${actual_abi} == "${expected_abi}" ]] ||
    die "${name}: the identity moved off its frozen value: ${actual_abi}"
  [[ ${actual_lock} == "${expected_lock}" ]] ||
    die "${name}: the canonical lock bytes moved off their frozen value: ${actual_lock}"
  [[ ${actual_manifest} == "${expected_manifest}" ]] ||
    die "${name}: the bytes the images carry moved off their frozen value: ${actual_manifest}"
  case ${expectation} in
    stable)
      [[ ${expected_abi} == "${abi_id_v0}" ]] ||
        die "${name}: a stable vector must carry V0's identity"
      # The lock file still moves here -- it is repository content, and a policy edit really does
      # change it. What must NOT move is the document the published images carry, asserted next.
      [[ ${expected_lock} != "${lock_digest_v0}" ]] ||
        die "${name}: a policy field left the lock file alone, so this vector no longer isolates
            the field it claims to change and its digests cannot be re-derived from anything"
      [[ ${expected_manifest} == "${manifest_digest_v0}" ]] ||
        die "${name}: a field outside the identity domain changed the bytes the images carry"
      ;;
    changes)
      [[ ${expected_abi} != "${abi_id_v0}" ]] ||
        die "${name}: a field inside the identity domain left the identity unchanged"
      [[ ${expected_lock} != "${lock_digest_v0}" ]] ||
        die "${name}: a field inside the domain did not change the canonical bytes"
      [[ ${expected_manifest} != "${manifest_digest_v0}" ]] ||
        die "${name}: a field inside the identity domain left the embedded document unchanged"
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
  stable "${abi_id_v0}" sha256:92b3f94aa609d53240d36a0293d9d4da31591c3c4876d68c37993a35f8115233
vector 'amd64-runner-label' '.release.ci.runners.amd64 = "ubuntu-24.04-alt"' \
  stable "${abi_id_v0}" sha256:daa63b075b9d69fc593ea06b90374b997ff0b8c8dc4dff8ee7f85766edfeecfc
vector 'sdk-repository-name' '.release.sdk_image = "rulego-plugin-sdk-alt"' \
  stable "${abi_id_v0}" sha256:815d4c0088149ac0aabb4f265a0abe48e8eb263f2c60e683672f89d61a670163
vector 'runtime-repository-name' '.release.runtime_image = "rulego-server-alt"' \
  stable "${abi_id_v0}" sha256:1744c319f14d105a086fe22a7a5b7d0cc5cbb3d64fcc649c22a2d14a8d595967
vector 'embedded-manifest-path' '.release.manifest_path = "/other/plugin-abi.json"' \
  stable "${abi_id_v0}" sha256:7df4fc4c0678f7284ee3b664ef67d9885cd6419abcecddeb3e3dcb857b9f1f4c
vector 'reproducible-epoch' '.release.reproducible_epoch = 1700000001' \
  stable "${abi_id_v0}" sha256:c4b91547d417dfda90936e82c6f215ea164c1236acc53703fc9298bf7e9ab19e
vector 'editor-asset-digest' \
  '.release.editor_payload.asset.sha256 =
     "0000000000000000000000000000000000000000000000000000000000000001"' \
  stable "${abi_id_v0}" sha256:14b357bdfa545d84524d92de489047705d439ebd09f50936b3763fb2374a8dab
vector 'previous-sdk-index-digest' \
  '.compatibility.previous_sdk.index_digest =
     "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  stable "${abi_id_v0}" sha256:0c865382fd8fef68fc9b15a50c762a4f85c6ff62c83cb28cb290f2696c19b2f8

# Changes: fields inside the domain. Both the identity and the canonical bytes are frozen, so
# the direction and the magnitude are each asserted separately.
vector 'go-version' '.abi.go.version = "1.25.1"' \
  changes abi-a577d039a624a73ade51bd7466f1782b91f05073ab5d26825d2c838fb0cbb5d1 \
    sha256:e07bddeecbab0ad770899a923ff83f4bafc736de23e101284b404e43f0406b05
vector 'module-graph-list-digest' \
  '.abi.module_graph.list_sha256 =
     "0000000000000000000000000000000000000000000000000000000000000001"' \
  changes abi-ad0cf58959b60a9589640094cfaedc02d6488340ade20242b076e6d0403d8af8 \
    sha256:9b29d7700e85ee2e020af41108509f17c76047d91e23b423bc3e1f63b5ecfb29
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
  changes abi-851b2d7c4c718b50c26aebcbfd2121cfcc8da45f986a73bac0996fcaa3113a6e \
    sha256:d9f7adca95f5998109f793198fb61035c26e6d1bb961d1f10030b6a093354c26
vector 'host-tags-cleared' '.abi.build.hosts[1].tags = []' \
  changes abi-272891d9dbf887f4c67c62e8e403eb293d7e34d3b2fd7741f00c476d664aa345 \
    sha256:204b9c1cfc32f3375fb13d432eab6046c47c1dd18bbbb869534d6a61149a55a7
# The recipe is inside the domain. A packaging generation that moves must move the identity, because
# that is the mechanism by which new bytes arrive under a name nobody has spent: measured on the live
# registry, `abi-f972e691` and `abi-78737478` are canonical tags held by artifacts this recipe cannot
# reproduce, and without this field the only remedy left to the gate was to wait for an upstream
# release version.
vector 'packaging-generation' '.abi.packaging.version = "4"' \
  changes abi-c47c1fe983d1bcefeb1bef05f87f72ae12d839c1a976a2732dba581f59da57a2 \
    sha256:954c59b3dd9b22d0a9b67046162df6d6d785708c9ef8420d07a99dc24ecc6801

# The gap this file used to record, and the four ways it is now closed.
#
# `20cc5f4` argued that packaging fields must not rename an image because they are not compiled
# into one. Measured, that was not the whole truth: `render manifest` canonicalized the WHOLE
# lock, that manifest was copied into the SDK image, `render sdk-env` wrote LOCK_DIGEST into
# /opt/rulego/build.env, and the SDK's own RUN asserted sha256(/abi-manifest.json) == LOCK_DIGEST.
# A policy-only edit therefore left the identity alone while moving the bytes of the image that
# identity names. The fix was to stop the lock's release half from reaching an image at all.
# Each assertion below is a refusal, so the gap can only reopen by being noticed.
epoch_lock=$(lock_digest_of "${test_root}/reproducible-epoch.stamped.json")
epoch_manifest=$(manifest_digest_of "${test_root}/reproducible-epoch.stamped.json")

# Derive mode stops here and reports what the shipped lock actually is, so the frozen literals can
# be rewritten from measurements instead of from the values they are about to be checked against.
if [[ ${PLUGIN_ABI_DERIVE:-0} == 1 ]]; then
  printf 'V0\t%s\t%s\t%s\n' "${abi_id_v0}" "${lock_digest_v0}" \
    "$(manifest_digest_of plugin-abi.lock)"
  exit 0
fi

[[ $(jq -r '.abi_id' "${test_root}/reproducible-epoch.stamped.json") == "${abi_id_v0}" ]] ||
  die 'the epoch is supposed to leave the identity alone'
[[ ${epoch_lock} != "${lock_digest_v0}" ]] ||
  die 'the epoch vector stopped changing the lock file, so it measures nothing'
[[ ${epoch_manifest} == "${manifest_digest_v0}" ]] ||
  die 'a policy-only edit moved the document the published images carry: the gap is open again'

# The manifest carries the identity and nothing else. Checked by shape rather than by a digest
# comparison, because a digest can be re-stamped and a key set cannot be argued into agreement.
[[ $(scripts/plugin-abi.sh render manifest | jq -r 'keys | join(",")') == "abi,abi_id" ]] ||
  die 'the embedded manifest reached outside the identity domain'

# The SDK environment is a file inside the image, so it must carry the identity document's digest
# and must not carry the lock's. Presence of the first and absence of the second are both asserted:
# deleting the export would otherwise pass as a fix.
sdk_env=$(scripts/plugin-abi.sh render sdk-env amd64)
grep -Fq 'ABI_MANIFEST_DIGEST=' <<<"${sdk_env}" ||
  die 'the SDK build environment no longer carries the digest of what the image embeds'
if grep -Fq 'LOCK_DIGEST=' <<<"${sdk_env}"; then
  die 'the whole-lock digest is back inside the SDK build environment'
fi

# The image labels are child-config bytes, so the same rule applies to them, and the recipe has to
# check the file it ships against the value that ships with it.
labels=$(scripts/plugin-abi.sh render metadata plugin-sdk amd64)
grep -Fq 'io.rulego.abi.manifest.digest' <<<"${labels}" ||
  die 'the SDK label set no longer names the embedded document'
if grep -Fq 'io.rulego.abi.lock.digest' <<<"${labels}"; then
  die 'the SDK label set pins the whole lock again'
fi
# The two halves have to appear on the same line: a recipe that mentions the variable and compares
# the file to something else would otherwise pass a name-only grep.
grep -Eq 'sha256:.*sha256sum /abi-manifest\.json.*= "\$\{ABI_MANIFEST_DIGEST\}"' Dockerfile.plugin-sdk ||
  die 'the SDK recipe no longer compares the shipped manifest to the identity-document digest'

# Where the whole lock still belongs: outside the image, answered on demand. The record and the
# evidence both cite it, and a reader who wants the file itself can still get its digest.
[[ $(scripts/plugin-abi.sh render lock-digest) == "${lock_digest_v0}" ]] ||
  die 'the lock digest stopped being computable outside the image'

if [[ ${PLUGIN_ABI_DERIVE:-0} == 1 ]]; then
  printf 'V0\t%s\t%s\t%s\n' "${abi_id_v0}" "${lock_digest_v0}" "${manifest_digest_v0}"
  printf 'LOCK_V0\t%s\n' "${lock_digest_v0}"
else
  printf 'Plugin ABI golden identity vectors passed: 13 vectors, and the release half of the lock is out of the image bytes.\n'
fi
