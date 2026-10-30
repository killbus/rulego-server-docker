#!/usr/bin/env bash
# shellcheck disable=SC2016

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

mkdir -p "${repository_root}/tmp"
test_root=$(mktemp -d "${repository_root}/tmp/plugin-abi-drivers.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

expect_failure() {
  local expected=$1
  shift
  if "$@" >"${test_root}/stdout" 2>"${test_root}/stderr"; then
    printf 'expected command to fail: %s\n' "$*" >&2
    exit 1
  fi
  grep -Fq "${expected}" "${test_root}/stderr"
}

expect_failure 'run only in GitHub Actions' env -u GITHUB_ACTIONS scripts/plugin-abi-build.sh amd64
expect_failure 'unsupported build architecture' env GITHUB_ACTIONS=true scripts/plugin-abi-build.sh riscv64
expect_failure 'runs only in GitHub Actions' env -u GITHUB_ACTIONS scripts/plugin-abi-publish.sh "${test_root}"
expect_failure 'requires PLUGIN_ABI_PUBLISH=true' env GITHUB_ACTIONS=true scripts/plugin-abi-publish.sh "${test_root}"

build=scripts/plugin-abi-build.sh
sdk_line=$(grep -n 'sdk_ref=${sdk_repository}@${sdk_child}' "${build}" | cut -d: -f1)
probe_line=$(grep -n '"${sdk_ref}" . "/output/sdk-probe-${arch}.so"' "${build}" | cut -d: -f1)
rootfs_line=$(grep -n -- '--entrypoint /usr/local/bin/build-plugin-host' "${build}" | cut -d: -f1)
# Anchored on the build invocation itself, because the reproducibility recheck
# also names the recipe: matching the bare file name would resolve to two lines
# and turn this ordering guard into an arithmetic error.
runtime_line=$(grep -n -- '--file "${repository_root}/Dockerfile.plugin-runtime"' "${build}" | cut -d: -f1)
stage_line=$(grep -n 'imagetools create --tag "${sdk_staging}"' "${build}" | cut -d: -f1)
size_line=$(grep -n 'runtime_uncompressed=$(docker image inspect' "${build}" | cut -d: -f1)
((sdk_line < probe_line && probe_line < rootfs_line && rootfs_line < runtime_line && runtime_line < size_line && size_line < stage_line))

grep -Fq 'GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}' .github/workflows/plugin-abi.yml
grep -Fq 'GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}' .github/workflows/plugin-abi-publish.yml

# Staging writes and the immutable-tag release gate are separate switches, so a
# measurement-state contract can still stage commit-qualified images.
grep -Fq 'stage=${PLUGIN_ABI_STAGE:-false}' "${build}"
(( $(grep -Fc 'if [[ ${publish} == true ]]; then' "${build}") == 1 )) || {
  echo 'only the release gate may branch on PLUGIN_ABI_PUBLISH in the build driver' >&2
  exit 1
}
(( $(grep -Fc 'if [[ ${stage} == true ]]; then' "${build}") == 3 )) || {
  echo 'every commit-qualified staging write must branch on PLUGIN_ABI_STAGE' >&2
  exit 1
}
grep -Fq 'PLUGIN_ABI_PUBLISH=true also requires PLUGIN_ABI_STAGE=true' "${build}"
grep -Fq 'PLUGIN_ABI_STAGE: "true"' .github/workflows/plugin-abi-publish.yml
grep -Fq 'PLUGIN_ABI_PUBLISH: ${{ github.event.inputs.publish }}' .github/workflows/plugin-abi-publish.yml
grep -Fq 'dispatch requires publish=true or staging_only=true' .github/workflows/plugin-abi-publish.yml

expect_failure 'PLUGIN_ABI_PUBLISH=true also requires PLUGIN_ABI_STAGE=true' env \
  GITHUB_ACTIONS=true PLUGIN_ABI_PUBLISH=true scripts/plugin-abi-build.sh amd64

grep -Fq '.index_digest' scripts/plugin-abi-publish.sh
grep -Fq '.sdk.child_digest' scripts/plugin-abi-publish.sh
grep -Fq 'selector=".runtime[\"${host_id}\"]"' scripts/plugin-abi-publish.sh
grep -Fq 'runtime_staging_indexes' scripts/plugin-abi-publish.sh
grep -Fq -- '--argjson runtime "${runtime_refs}"' scripts/plugin-abi-publish.sh
grep -Fq '"${runtime_staging_indexes}" release' scripts/plugin-abi-publish.sh
grep -Fq -- '--argjson runtime "${runtime_evidence}"' scripts/plugin-abi-build.sh
grep -Fq 'component "${runtime_ref}" "${arch}"' scripts/plugin-abi-build.sh
grep -Fq '"${component_expectation}" ai/agent' scripts/plugin-abi-build.sh
grep -Fq 'render compatibility-sdk "${arch}"' scripts/plugin-abi-build.sh
grep -Fq "legacy_abi_id=\$(jq -er '.abi_id' <<<\"\${compatibility_json}\")" scripts/plugin-abi-build.sh
grep -Fq "legacy_sdk_ref=\$(jq -er '.reference' <<<\"\${compatibility_json}\")" scripts/plugin-abi-build.sh
grep -Fq '"${legacy_sdk_ref}" . "/output/legacy-sdk-probe-${arch}.so"' scripts/plugin-abi-build.sh
grep -Fq 'load "${runtime_ref}" "${arch}" "${work}/sdk-output/legacy-sdk-probe-${arch}.so"' scripts/plugin-abi-build.sh
if grep -Eq 'legacy_sdk_ref=.*rulego-plugin-sdk:|compatibility\.previous_sdk\.repository.*:' scripts/plugin-abi-build.sh; then
  echo 'legacy compatibility probe uses a mutable tag instead of a digest pin' >&2
  exit 1
fi
grep -Fq 'publish_immutable_image_tag' scripts/plugin-abi-publish.sh
grep -Fq 'immutable tag already points to a different digest' scripts/lib.sh
# The pre-write probe must stay wired into publication, not just defined.
grep -Fq 'require_immutable_tags_publishable "${canonical_plan}"' scripts/plugin-abi-publish.sh
# Every canonical write must come after the probe, so a conflict leaves no
# partially published release behind.
probe_line=$(grep -n 'require_immutable_tags_publishable "${canonical_plan}"' scripts/plugin-abi-publish.sh | cut -d: -f1)
first_write_line=$(grep -n 'publish_immutable_image_tag ' scripts/plugin-abi-publish.sh | head -n 1 | cut -d: -f1)
((probe_line < first_write_line)) || {
  echo 'the canonical tag probe must run before the first canonical write' >&2
  exit 1
}

# Reproducibility wiring: the runtime context must be stamped and probed before
# its image is built, and both image builds must carry the locked epoch, or the
# child digest silently returns to the build clock and every gate rejection
# fires for the trivial known reason.
(( $(grep -Fc 'stamp_reproducible_tree "${runtime_context}"' "${build}") == 1 )) || {
  echo 'the runtime context must be stamped exactly once before it is built' >&2
  exit 1
}
(( $(grep -Fc 'assert_reproducible_tree "${runtime_context}"' "${build}") == 1 )) || {
  echo 'the runtime context must be probed exactly once before it is built' >&2
  exit 1
}
runtime_stamp_line=$(grep -n 'stamp_reproducible_tree "${runtime_context}"' "${build}" | cut -d: -f1)
runtime_assert_line=$(grep -n 'assert_reproducible_tree "${runtime_context}"' "${build}" | cut -d: -f1)
((runtime_stamp_line < runtime_assert_line && runtime_assert_line < runtime_line)) || {
  echo 'the runtime context must be stamped and probed before the runtime image is built' >&2
  exit 1
}
# Three pinning sites for four image builds: the SDK, the runtime, and the
# recheck helper that reproduces both. A build that forgets the epoch silently
# returns the child digest to the wall clock, so the count is the guard.
(( $(grep -Fc 'env SOURCE_DATE_EPOCH="${reproducible_epoch}"' "${build}") == 3 )) || {
  echo 'every Plugin ABI image build, including the reproducibility recheck, must pin SOURCE_DATE_EPOCH' >&2
  exit 1
}
prepare_stamp_line=$(grep -n 'stamp_reproducible_tree "${stage_root}"' scripts/prepare-plugin-abi.sh | cut -d: -f1)
prepare_assert_line=$(grep -n 'assert_reproducible_tree "${stage_root}"' scripts/prepare-plugin-abi.sh | cut -d: -f1)
prepare_move_line=$(grep -n 'mv -- "${context}" "${destination}"' scripts/prepare-plugin-abi.sh | cut -d: -f1)
((prepare_stamp_line < prepare_assert_line && prepare_assert_line < prepare_move_line)) || {
  echo 'the prepared context must be stamped and probed before it reaches the build root' >&2
  exit 1
}
# Pruning belongs at the one boundary where nothing that writes is left to run,
# which is where the stamp already sits. Pruning next to `mod download all`
# looks equivalent but is not: any later command that resolves modules can
# re-open the log, and a witness that appears after the boundary is invisible
# to both the stamp and the probe. The ordering is asserted rather than
# assumed because moving one line is how this class of drift came back.
prepare_prune_line=$(grep -n 'rm -rf -- "${sumdb_witness}"' scripts/prepare-plugin-abi.sh | cut -d: -f1)
last_module_line=$(grep -n 'run_go "${resolver_dir}" list -m -f' scripts/prepare-plugin-abi.sh | tail -n 1 | cut -d: -f1)
((last_module_line < prepare_prune_line && prepare_prune_line < prepare_move_line)) || {
  echo 'the transparency-log witness must be pruned after the last module command and before the context is moved' >&2
  exit 1
}
# The nested-destination rule for the recipes is asserted once, in
# tests/plugin-image-contract.sh.

# Reproducibility recheck wiring. The recheck is the only place the pipeline's
# own identity claim is tested on the infrastructure that produces it, so it
# must sit between the first build and the first write: after the build, or it
# proves nothing about that build; before any staging write, or a recipe that
# reproduces only sometimes would already have published.
recheck_sdk_line=$(grep -n 'sdk_recheck=$(reproduce_recheck' "${build}" | cut -d: -f1)
recheck_runtime_line=$(grep -n 'runtime_recheck=$(reproduce_recheck' "${build}" | cut -d: -f1)
((sdk_line < recheck_sdk_line && recheck_sdk_line < stage_line)) || {
  echo 'the SDK reproducibility recheck must run after its build and before staging' >&2
  exit 1
}
runtime_staging_line=$(grep -n 'imagetools create --tag "${runtime_staging}"' "${build}" | cut -d: -f1)
((runtime_line < recheck_runtime_line && recheck_runtime_line < runtime_staging_line)) || {
  echo 'the runtime reproducibility recheck must run after its build and before staging' >&2
  exit 1
}
# --no-cache is load-bearing, not a speed choice: measured on buildkit
# v0.33.1, a warm second build in one builder replays the cached RUN layer
# instead of re-running it, so the recheck would compare identical bytes and
# pass against an unpinned recipe.
grep -Fq -- '--no-cache --file "${dockerfile}"' "${build}" || {
  echo 'the reproducibility recheck must bypass the builder cache' >&2
  exit 1
}
# Every recheck call must pass the repository it rebuilt as its first argument.
# The label used for log and metadata names is derived from that value, so a
# variant or host id supplied here instead would write files outside ${work}:
# the first version took a separate label argument, one caller passed the
# repository in its place, and the build log redirect landed on a path named
# after localhost:5000/, which failed the job for a reason unrelated to the
# digest. Checking the call sites catches the class rather than the instance.
while IFS= read -r call; do
  first=$(sed -E 's/.*reproduce_recheck "([^"]+)".*/\1/' <<<"${call}")
  [[ ${first} =~ ^\$\(?\{[a-z_]*repository\}$ ]] || {
    printf 'the reproducibility recheck must be called with its repository first: %s\n' "${call}" >&2
    exit 1
  }
done < <(grep -E '(sdk|runtime)_recheck=\$\(reproduce_recheck' "${build}")
# Only the image child is compared. An index digest moves on every build because
# the attestation member carries the invocation identity, so a check written at
# that granularity would be permanently red and then get weakened until it was
# meaningless.
grep -Fq 'SDK child digest is not reproducible' "${build}" || {
  echo 'the SDK recheck must fail with its own reason' >&2
  exit 1
}
grep -Fq 'runtime child digest is not reproducible' "${build}" || {
  echo 'the runtime recheck must fail with its own reason' >&2
  exit 1
}

echo 'Plugin ABI driver guards and digest flow passed'
