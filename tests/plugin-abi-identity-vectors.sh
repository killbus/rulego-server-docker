#!/usr/bin/env bash
# Golden identity vectors for the split identity model.
#
#   abi_id    = "abi-"    + sha256(jq -S -c '.abi' | tr -d CR)
#   recipe_id = "recipe-" + sha256(jq -S -c '.distribution.recipe' | tr -d CR)
#
# The expected values are frozen literals, not recomputations of themselves. The shipped lock
# must canonicalize to the two frozen domain files, and each vector pins the exact identity,
# recipe, whole-lock digest and embedded-manifest digest. Direction is asserted separately:
# ABI inputs move `abi_id`, recipe inputs move `recipe_id`, and distribution policy moves neither.

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

canonical_recipe_bytes() {
  jq -S -c '.distribution.recipe' "${1}" | tr -d '\r'
}

canonical_lock_bytes() {
  jq -S -c '.' "${1}" | tr -d '\r'
}

canonical_manifest_bytes() {
  jq -S -c '{abi_id, abi}' "${1}" | tr -d '\r'
}

hex_of() {
  sha256sum | awk '{print $1}'
}

abi_of_lock() {
  printf 'abi-%s\n' "$(canonical_abi_bytes "${1}" | hex_of)"
}

recipe_of_lock() {
  printf 'recipe-%s\n' "$(canonical_recipe_bytes "${1}" | hex_of)"
}

lock_digest_of() {
  printf 'sha256:%s\n' "$(canonical_lock_bytes "${1}" | hex_of)"
}

manifest_digest_of() {
  printf 'sha256:%s\n' "$(canonical_manifest_bytes "${1}" | hex_of)"
}

domain=tests/fixtures/plugin-abi-identity/domain.canonical
recipe_domain=tests/fixtures/plugin-abi-identity/recipe.canonical
[[ -f ${domain} && -f ${recipe_domain} ]] ||
  die 'the frozen identity domains are missing'

abi_id_v0=abi-feccf60c9e5fb611b2fb5e71bb606943a1be39d356050eea74ffb025962a050f
recipe_id_v0=recipe-33955b884529aa42bc1ece6b5c9894840a5e9c43ddae9d0b90998c2a57a5f806
lock_digest_v0=sha256:05db10ef7352afb2c19b2543acfc3d9b6c1f2a43ded96276d097487113055aa6
manifest_digest_v0=sha256:d6ec632cdadc7534f8f44441d58fd3fff6fbdc5655a7072618ec16f9587969a7

cmp -s <(canonical_abi_bytes plugin-abi.lock) "${domain}" ||
  die 'the shipped lock no longer canonicalizes to the frozen ABI domain'
cmp -s <(canonical_recipe_bytes plugin-abi.lock) "${recipe_domain}" ||
  die 'the shipped lock no longer canonicalizes to the frozen recipe domain'
[[ $(abi_of_lock plugin-abi.lock) == "${abi_id_v0}" ]] ||
  die 'the ABI identity of the shipped lock moved off its frozen value'
[[ $(recipe_of_lock plugin-abi.lock) == "${recipe_id_v0}" ]] ||
  die 'the recipe identity of the shipped lock moved off its frozen value'
[[ $(scripts/plugin-abi.sh render id) == "${abi_id_v0}" ]] ||
  die 'scripts/plugin-abi.sh render id disagrees with the frozen ABI identity'
[[ $(scripts/plugin-abi.sh render recipe-id) == "${recipe_id_v0}" ]] ||
  die 'scripts/plugin-abi.sh render recipe-id disagrees with the frozen recipe identity'
[[ $(scripts/plugin-abi.sh render lock-digest) == "${lock_digest_v0}" ]] ||
  die 'scripts/plugin-abi.sh render lock-digest disagrees with the frozen canonical lock'
[[ $(scripts/plugin-abi.sh render manifest-digest) == "${manifest_digest_v0}" ]] ||
  die 'scripts/plugin-abi.sh render manifest-digest disagrees with the frozen identity document'

# vector <name> <filter> <abi stable|changes> <recipe stable|changes>
#        <expected abi> <expected recipe> <expected lock> <expected manifest>
vector() {
  local name=$1 filter=$2 abi_expectation=$3 recipe_expectation=$4
  local expected_abi=$5 expected_recipe=$6 expected_lock=$7 expected_manifest=$8
  local actual_abi actual_recipe actual_lock actual_manifest
  jq "${filter}" plugin-abi.lock >"${test_root}/${name}.json" 2>"${test_root}/${name}.jq" ||
    die "${name}: mutation rejected by jq: $(cat "${test_root}/${name}.jq")"
  jq --arg abi "$(abi_of_lock "${test_root}/${name}.json")" \
    --arg recipe "$(recipe_of_lock "${test_root}/${name}.json")" \
    '.abi_id = $abi | .recipe_id = $recipe' \
    "${test_root}/${name}.json" >"${test_root}/${name}.stamped.json"
  PLUGIN_ABI_LOCK=${test_root}/${name}.stamped.json \
    scripts/plugin-abi.sh validate --candidate >"${test_root}/${name}.validate" 2>&1 ||
    die "${name}: not a legal lock: $(tail -n 1 "${test_root}/${name}.validate")"
  actual_abi=$(abi_of_lock "${test_root}/${name}.stamped.json")
  actual_recipe=$(recipe_of_lock "${test_root}/${name}.stamped.json")
  actual_lock=$(lock_digest_of "${test_root}/${name}.stamped.json")
  actual_manifest=$(manifest_digest_of "${test_root}/${name}.stamped.json")

  [[ ${actual_abi} == "${expected_abi}" ]] ||
    die "${name}: ABI identity moved off its frozen value: ${actual_abi}"
  [[ ${actual_recipe} == "${expected_recipe}" ]] ||
    die "${name}: recipe identity moved off its frozen value: ${actual_recipe}"
  [[ ${actual_lock} == "${expected_lock}" ]] ||
    die "${name}: whole-lock digest moved off its frozen value: ${actual_lock}"
  [[ ${actual_manifest} == "${expected_manifest}" ]] ||
    die "${name}: embedded document moved off its frozen value: ${actual_manifest}"
  [[ ${expected_lock} != "${lock_digest_v0}" ]] ||
    die "${name}: the mutation did not change the lock file, so the vector measures nothing"

  case ${abi_expectation} in
    stable)
      [[ ${expected_abi} == "${abi_id_v0}" ]] || die "${name}: stable vector moved abi_id"
      [[ ${expected_manifest} == "${manifest_digest_v0}" ]] ||
        die "${name}: a field outside the ABI domain moved the embedded document"
      ;;
    changes)
      [[ ${expected_abi} != "${abi_id_v0}" ]] || die "${name}: ABI vector left abi_id unchanged"
      [[ ${expected_manifest} != "${manifest_digest_v0}" ]] ||
        die "${name}: ABI vector left the embedded document unchanged"
      ;;
    *) die "${name}: unknown ABI expectation: ${abi_expectation}" ;;
  esac
  case ${recipe_expectation} in
    stable)
      [[ ${expected_recipe} == "${recipe_id_v0}" ]] || die "${name}: stable vector moved recipe_id"
      ;;
    changes)
      [[ ${expected_recipe} != "${recipe_id_v0}" ]] || die "${name}: recipe vector left recipe_id unchanged"
      ;;
    *) die "${name}: unknown recipe expectation: ${recipe_expectation}" ;;
  esac
}

# Distribution policy: neither identity moves, and the embedded document does not move either.
vector release-ready \
  '.distribution.release.state = "ready"
     | (.distribution.release.size_limits[] | .sdk.compressed, .sdk.uncompressed,
        .runtime[].compressed, .runtime[].uncompressed) = 1' \
  stable stable \
  "${abi_id_v0}" "${recipe_id_v0}" \
  sha256:da00e5d7b0e047f456d3ba0e5485d24f0a091e03a340b969b070e0b6e29615eb \
  "${manifest_digest_v0}"
vector amd64-runner \
  '.distribution.release.ci.runners.amd64 = "ubuntu-24.04-alt"' \
  stable stable \
  "${abi_id_v0}" "${recipe_id_v0}" \
  sha256:b71ecbc24d731e77dc5c67655c8cdb4d6a6ed984831171820956f564406680c3 \
  "${manifest_digest_v0}"
vector sdk-repository \
  '.distribution.release.sdk_image = "rulego-plugin-sdk-alt"' \
  stable stable \
  "${abi_id_v0}" "${recipe_id_v0}" \
  sha256:fa848385c6b7d5f406aaf55bf8de3279dee73bfaf4731c9e1692fa244551f5ae \
  "${manifest_digest_v0}"
vector runtime-repository \
  '.distribution.release.runtime_image = "rulego-server-alt"' \
  stable stable \
  "${abi_id_v0}" "${recipe_id_v0}" \
  sha256:7b80caa6cdb8cc4f827a7b9bafa0da8522d8f60dc801907151604b42949f047b \
  "${manifest_digest_v0}"
vector previous-sdk-index \
  '.distribution.compatibility.previous_sdk.index_digest =
     "sha256:0000000000000000000000000000000000000000000000000000000000000001"' \
  stable stable \
  "${abi_id_v0}" "${recipe_id_v0}" \
  sha256:8c0118bb6bbec439c84c1c0b61d465df4de47b237c6b5ccface0ea853086ab79 \
  "${manifest_digest_v0}"

# Recipe inputs: abi_id stays, recipe_id moves.
vector embedded-manifest-path \
  '.distribution.recipe.manifest_path = "/other/plugin-abi.json"' \
  stable changes \
  "${abi_id_v0}" recipe-c71282e8a75c277a5d094a78b1253d0635ba12fb6ff82471cc19fc9828abe0ac \
  sha256:a1224c1084ee451efbdd3cac86f1ce76f3d22ad2ac83d942553f3581e8bac4a2 \
  "${manifest_digest_v0}"
vector reproducible-epoch \
  '.distribution.recipe.reproducible_epoch = 1700000001' \
  stable changes \
  "${abi_id_v0}" recipe-690daf69922a5933bd7544c3d4724713ea6d25c59f34679cb9ad6b3f294ec9d7 \
  sha256:46e185ff4fa2cefbf7200d845f5311626d70e1579560d984d8e2a2b75e666548 \
  "${manifest_digest_v0}"
vector editor-asset-digest \
  '.distribution.recipe.editor_payload.asset.sha256 =
     "0000000000000000000000000000000000000000000000000000000000000001"' \
  stable changes \
  "${abi_id_v0}" recipe-109dde2c22ad9c995af1cd99c26e429732c206c53be8981383ea9e41fdadbac8 \
  sha256:1c263da757cb07a585923a67dedd158ee638dccd192654315b08c7d37d0e3c2d \
  "${manifest_digest_v0}"

# ABI inputs: abi_id moves, recipe_id stays.
vector go-version '.abi.go.version = "1.25.1"' \
  changes stable \
  abi-8a2a4fb314fbbea0e4f56f6a38904ab95a499658e91b0ee3cdcca988ecfe2754 "${recipe_id_v0}" \
  sha256:652636647860089d4d59cbfabf79d74f7a805fd46adcfd6641d54bcb0e497553 \
  sha256:173b16c284edf19582b29a1e4b268ce69d04480bf3d518d1a9cfd64933ad5e62
vector module-graph-list-digest \
  '.abi.module_graph.list_sha256 =
     "0000000000000000000000000000000000000000000000000000000000000001"' \
  changes stable \
  abi-a3e18a99e4b2272aa2588de334620f94411bb34596dddc48e8ea7d4e966fc5cc "${recipe_id_v0}" \
  sha256:49338a5dd770aa9ca6010b8c025247097037d91c4dcfe540a849d4dc13e75744 \
  sha256:4d1dc96336b92049d80ce4fe995f678009ad83939f920dab1d36310a82e2fa33
vector server-revision \
  '.abi.rulego_server.revision = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  changes stable \
  abi-dca86d5f6fc70f999ae905eaa4330d55800a8caf8bac6a4caed157bfd9c87ca1 "${recipe_id_v0}" \
  sha256:3cf78b4f14136cfaae0816a1d33f2cc45fdd9b6b7586d078d8090bf6ead81a30 \
  sha256:4264d13e8a13cbe35b216775abfe120e522bf8a05edd575eb87e56a3002a0a28
vector core-revision \
  '.abi.rulego_core.revision = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  changes stable \
  abi-b50607b53ef0becc455795d8e23b83e96e1ea990ed6541bc320cc1c80bec43bc "${recipe_id_v0}" \
  sha256:4add92312cfef676c30d3bb04ca4e217d0a4aa10def721f47a7dcf14ccd05fd3 \
  sha256:d6e142dd01f8fde65b0037fa4bd1777da16494b44c503d5241c90cf8564f1458

# The schema keeps distribution out of `.abi`; a lock that reintroduces any removed field is a
# contract regression, not a harmless addition.
jq -e '(.abi.build | has("hosts") | not) and
  (.abi.build | has("plugin_symbol") | not) and
  (.abi.build | has("plugin_workspace") | not) and
  (.abi | has("packaging") | not) and
  (.abi.rulego_server | has("module") | not)' plugin-abi.lock >/dev/null ||
  die 'a field removed from the ABI identity has returned to .abi'
jq -e '.distribution.hosts == [
  {"id":"plugin","tags":[],"tag_suffix":"-plugin"},
  {"id":"ai-plugin","tags":["with_ai"],"tag_suffix":"-ai-plugin"},
  {"id":"all-plugin","tags":["with_all"],"tag_suffix":"-all-plugin"}
]' plugin-abi.lock >/dev/null || die 'the distribution host list is not the three locked peers'

ready=${test_root}/ready.json
jq '.distribution.release.state = "ready" |
  (.distribution.release.size_limits[] | .sdk.compressed, .sdk.uncompressed,
    .runtime[].compressed, .runtime[].uncompressed) = 1' plugin-abi.lock >"${ready}"
PLUGIN_ABI_LOCK=${ready} scripts/plugin-abi.sh validate --release
recipe_tag=${recipe_id_v0#recipe-}
recipe_tag=${recipe_tag:0:12}
name_revision=1111111111111111111111111111111111111111
tags=$(PLUGIN_ABI_LOCK=${ready} PLUGIN_ABI_NAME_REVISION=${name_revision} \
  scripts/plugin-abi.sh render tags)
jq -e --arg abi "${abi_id_v0}" --arg recipe "${recipe_tag}" '
  (keys | sort) == ["runtime","sdk"] and
  .sdk == ("rulego-plugin-sdk:" + $abi + "-r" + $recipe) and
  (.runtime | keys | sort) == ["ai-plugin","all-plugin","plugin"] and
  (.runtime | all(.[]; .canonical != null and .alias != null)) and
  .runtime["plugin"].canonical == ("rulego-server:v1.0.0-plugin-r" + $recipe + "-111111111111") and
  .runtime["plugin"].alias == "rulego-server:v1.0.0-plugin" and
  .runtime["ai-plugin"].canonical == ("rulego-server:v1.0.0-ai-plugin-r" + $recipe + "-111111111111") and
  .runtime["ai-plugin"].alias == "rulego-server:v1.0.0-ai-plugin" and
  .runtime["all-plugin"].canonical == ("rulego-server:v1.0.0-all-plugin-r" + $recipe + "-111111111111") and
  .runtime["all-plugin"].alias == "rulego-server:v1.0.0-all-plugin"
' <<<"${tags}" >/dev/null || die 'the rendered tag plan is not one SDK plus three canonical/alias pairs'
if grep -Fq 'latest-plugin' <<<"${tags}"; then
  die 'the tag plan invented a latest-plugin name'
fi

tags_none=$(PLUGIN_ABI_LOCK=${ready} PLUGIN_ABI_NAME_REVISION=none \
  scripts/plugin-abi.sh render tags --candidate)
jq -e --arg abi "${abi_id_v0}" --arg recipe "${recipe_tag}" '
  .sdk == ("rulego-plugin-sdk:" + $abi + "-r" + $recipe) and
  (.runtime | all(.[]; .canonical == null and .alias != null))
' <<<"${tags_none}" >/dev/null || die 'the pre-build render must name no canonical runtime'

# The SDK environment and labels are bytes inside the images. They carry the identity document's
# digest, not the whole-lock digest, and they carry no host distribution identity.
sdk_env=$(scripts/plugin-abi.sh render sdk-env amd64)
grep -Fq 'ABI_MANIFEST_DIGEST=' <<<"${sdk_env}" ||
  die 'the SDK build environment no longer carries the digest of what the image embeds'
if grep -Fq 'LOCK_DIGEST=' <<<"${sdk_env}"; then
  die 'the whole-lock digest is back inside the SDK build environment'
fi
if grep -Eq '^(HOST_ID|HOST_TAGS|HOST_VARIANTS|SERVER_REVISION|PLUGIN_WORKSPACE)=' <<<"${sdk_env}"; then
  die 'host distribution identity is back inside the SDK build environment'
fi

sdk_labels=$(scripts/plugin-abi.sh render metadata plugin-sdk amd64)
jq -e --arg recipe "${recipe_id_v0}" '
  ."io.rulego.recipe.id" == $recipe and
  (has("io.rulego.host") | not) and
  (has("io.rulego.abi.lock.digest") | not)
' <<<"${sdk_labels}" >/dev/null || die 'the SDK label set reached outside the split identity'
runtime_labels=$(scripts/plugin-abi.sh render metadata plugin-runtime amd64 ai-plugin)
jq -e '."io.rulego.host" == "ai-plugin" and
  ."io.rulego.host.tags" == "with_ai" and
  (has("io.rulego.abi.host") | not)' <<<"${runtime_labels}" >/dev/null ||
  die 'the runtime label set does not describe its host distribution identity'

grep -Eq 'sha256:.*sha256sum /abi-manifest\.json.*= "\$\{ABI_MANIFEST_DIGEST\}"' Dockerfile.plugin-sdk ||
  die 'the SDK recipe no longer compares the shipped manifest to the identity-document digest'

printf 'Plugin ABI identity vectors: 12 vectors and the tag plan held.\n'
