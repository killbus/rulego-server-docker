#!/usr/bin/env bash
# shellcheck disable=SC2016

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

assert_contains() {
  grep -Fq -- "$2" "$1" || { printf 'missing required contract in %s: %s\n' "$1" "$2" >&2; exit 1; }
}

assert_contains Dockerfile.plugin-sdk 'FROM ${SDK_BASE}'
assert_contains Dockerfile.plugin-sdk 'COPY --chown=65532:65532 gomodcache-root/ /'
assert_contains Dockerfile.plugin-sdk 'COPY --chown=0:0 stage-root/ /'
assert_contains Dockerfile.plugin-sdk 'ENTRYPOINT ["/usr/local/bin/rulego-plugin-build"]'
if grep -Fq 'runtime/editor' Dockerfile.plugin-sdk; then
  echo 'plugin SDK bundles a runtime-only editor payload' >&2
  exit 1
fi
# Only the two staged roots may reach the SDK, each copied to the filesystem
# root: a directory-form COPY into a nested destination re-stamps its parent
# directories with the build clock, which would make the child digest depend
# on when the image is built.
if grep -Eq '^COPY( --chown=[^ ]+)? [^ ]+ /[^/]' Dockerfile.plugin-sdk Dockerfile.plugin-runtime; then
  echo 'Plugin ABI recipe copies to a nested destination instead of /' >&2
  exit 1
fi
assert_contains Dockerfile.plugin-runtime 'FROM ${RUNTIME_BASE}'
assert_contains Dockerfile.plugin-runtime 'COPY --chown=0:0 abi-root/ /'
assert_contains Dockerfile.plugin-runtime 'COPY --chown=65532:65532 app-root/ /'
assert_contains Dockerfile.plugin-runtime 'USER 65532:65532'
assert_contains Dockerfile.plugin-runtime 'VOLUME ["/app/data"]'
assert_contains Dockerfile.plugin-runtime 'ENTRYPOINT ["/app/rulego-server"]'
# The SDK version probe must run with a scratch HOME it deletes in the same
# RUN. With the inherited HOME the probe writes a Go telemetry counter whose
# file name carries the build date and whose contents carry the week of the
# build, which puts the wall clock into the child digest through the very layer
# that exists to prove the toolchain is the locked one. Asserting both halves
# here: the probe must be redirected, and the scratch directory must not
# survive into the layer.
assert_contains Dockerfile.plugin-sdk 'home=$(mktemp -d)'
assert_contains Dockerfile.plugin-sdk 'HOME="${home}" GOENV="${GOENV}" GOTOOLCHAIN="${GOTOOLCHAIN}" go env GOVERSION'
assert_contains Dockerfile.plugin-sdk 'rm -rf "${home}"'
if grep -Eq 'test "\$\(\s*GOENV="\$\{GOENV\}"' Dockerfile.plugin-sdk; then
  echo 'the SDK version probe reads the toolchain with the inherited HOME, which writes a dated telemetry counter into the image' >&2
  exit 1
fi
if grep -Eq 'SDK_BASE|build-plugin-host|rulego-plugin-build|/go/pkg/mod|/opt/rulego/source' Dockerfile.plugin-runtime; then
  echo 'runtime recipe references the SDK or build payload' >&2
  exit 1
fi
[[ $(grep -c '^FROM ' Dockerfile.plugin-runtime) == 1 ]]
assert_contains .dockerignore '!Dockerfile.plugin-sdk'
assert_contains .dockerignore '!Dockerfile.plugin-runtime'

assert_contains scripts/plugin-abi-build.sh 'SDK_BASE=${sdk_base}'
assert_contains scripts/plugin-abi-build.sh '"${sdk_ref}" . "/output/sdk-probe-${arch}.so"'
assert_contains scripts/plugin-abi-build.sh '"${legacy_sdk_ref}" . "/output/legacy-sdk-probe-${arch}.so"'
assert_contains scripts/plugin-abi-build.sh 'render compatibility-sdk "${arch}"'
assert_contains scripts/plugin-abi-build.sh "legacy_sdk_ref=\$(jq -er '.reference' <<<\"\${compatibility_json}\")"
assert_contains scripts/plugin-abi-build.sh 'load "${runtime_ref}" "${arch}" "${work}/sdk-output/legacy-sdk-probe-${arch}.so"'
assert_contains scripts/plugin-abi-build.sh '--entrypoint /usr/local/bin/build-plugin-host'
assert_contains scripts/plugin-abi-build.sh 'Dockerfile.plugin-runtime'
assert_contains scripts/plugin-abi-build.sh 'staging-${packaging_revision}-${arch}${tag_suffix}'
# Image bytes are decided by the lock, not by which commit ran the build. A per-commit value in an
# image label or an index annotation moves the child digest of every artifact, so a canonical tag
# could never compare equal to its own content and republishing an unchanged contract would read as
# a conflict. These annotations therefore come from one file only: the lock renderer.
for annotation_recipe in scripts/plugin-abi-build.sh scripts/plugin-abi-publish.sh scripts/verify-plugin-oci.sh; do
  if grep -Fq 'org.opencontainers.image.' "${annotation_recipe}"; then
    printf '%s composes OCI annotations instead of taking them from scripts/plugin-abi.sh render metadata\n' \
      "${annotation_recipe}" >&2
    exit 1
  fi
done
if grep -R -E -q 'PLUGIN_ABI_PACKAGING_[A-Z]+=' scripts .github tests; then
  echo 'a packaging-derived annotation channel puts per-commit bytes back into published images' >&2
  exit 1
fi
assert_contains scripts/plugin-abi-build.sh '--env "RULEGO_HOST_ID=${host_id}"'
assert_contains scripts/build-plugin-host 'IFS='"'"';'"'"' read -r -a host_variants <<<"${HOST_VARIANTS}"'
if grep -Eq '(^|[^[:alnum:]_])jq([^[:alnum:]_]|$)' scripts/build-plugin-host; then
  echo 'host builder depends on jq, which is absent from compatibility SDK images' >&2
  exit 1
fi
assert_contains scripts/plugin-abi-build.sh 'verify-plugin-runtime.sh" load'
assert_contains scripts/plugin-abi-build.sh 'verify-plugin-runtime.sh" reject'
assert_contains scripts/plugin-abi-build.sh 'verify-plugin-runtime.sh" missing-libc'
assert_contains scripts/plugin-abi-build.sh '--provenance=mode=max --sbom=true'
assert_contains scripts/verify-plugin-runtime.sh 'docker volume create "${volume}"'
assert_contains scripts/verify-plugin-runtime.sh '--mount "type=volume,source=${volume},target=/app/data"'
assert_contains scripts/verify-plugin-runtime.sh '--mount "type=bind,source=${work}/plugins,target=/app/data/plugins,readonly"'
if grep -Fq '${work}/data:/app/data' scripts/verify-plugin-runtime.sh; then
  echo 'runtime verification bind-mounts non-root output into the runner workspace' >&2
  exit 1
fi
if grep -R -Fq 'all(. as ' -- scripts; then
  echo 'invalid jq all(generator; condition) syntax remains' >&2
  exit 1
fi
assert_contains scripts/plugin-abi-publish.sh 'publish_immutable_image_tag'
assert_contains scripts/lib.sh 'immutable tag already resolves to different images'
assert_contains scripts/plugin-abi-publish.sh 'verify-plugin-oci.sh'
assert_contains scripts/plugin-abi-publish.sh 'expected_staging=${runtime_repository}:staging-${packaging_revision}-${arch}${tag_suffix}'
assert_contains scripts/plugin-abi-publish.sh 'runtime_staging_indexes='
assert_contains scripts/verify-plugin-oci.sh 'render size-limit "${arch}" "${host_id}"'
assert_contains scripts/plugin-abi-build.sh 'dd of="${work}/wrong-arch.so"'
assert_contains scripts/plugin-abi-build.sh '-gcflags=all=-N'

verify_workflow=.github/workflows/plugin-abi.yml
publish_workflow=.github/workflows/plugin-abi-publish.yml
backfill_workflow=.github/workflows/plugin-abi-backfill.yml
assert_contains "${verify_workflow}" 'run: scripts/plugin-abi-build.sh "${{ matrix.goarch }}"'
assert_contains "${publish_workflow}" 'run: scripts/plugin-abi-build.sh "${{ matrix.goarch }}"'
assert_contains "${publish_workflow}" 'run: scripts/plugin-abi-publish.sh tmp/evidence'
assert_contains "${publish_workflow}" 'environment: plugin-abi-release'
assert_contains "${publish_workflow}" 'packages: write'
# The alias promotion is a separate step, run after the immutable names are written and verified. Its
# position is the contract: a step that moved `v1.0.0-<host>` before verification would advertise
# content nothing checked, and that is the exact ordering the two-phase publication exists to forbid.
# It is also given the record that publish writes, not a digest assembled from step outputs.
assert_contains "${publish_workflow}" 'run: scripts/promote-runtime-aliases.sh tmp/plugin-abi-release.json'
publish_step_line=$(grep -Fn 'run: scripts/plugin-abi-publish.sh tmp/evidence' "${publish_workflow}" | cut -d: -f1)
promote_step_line=$(grep -Fn 'run: scripts/promote-runtime-aliases.sh' "${publish_workflow}" | cut -d: -f1)
(( ${promote_step_line} > ${publish_step_line} )) || {
  echo 'the runtime alias promotion runs before the immutable publication it is licensed by' >&2
  exit 1
}
if grep -Fq 'packages: write' "${verify_workflow}"; then
  echo 'ordinary Plugin ABI verification requested package-write permission' >&2
  exit 1
fi
if grep -Eq 'docker (build|run|pull|create|image|buildx)|jq[[:space:]]|oras[[:space:]]' "${verify_workflow}" "${publish_workflow}" "${backfill_workflow}"; then
  echo 'Plugin ABI workflow contains repository business logic' >&2
  exit 1
fi
if grep -Eq 'packaging_correction|packaging-correction|oci\.tar|oras-project' "${verify_workflow}" "${publish_workflow}" README.md plugin-abi.lock scripts/plugin-abi*.sh; then
  echo 'removed candidate-transport or packaging-correction path remains' >&2
  exit 1
fi

# The backfill is the only path that writes a name for bytes this pipeline did not build, so its
# ordering is asserted the same way the promotion's is: the read-only proof runs first, and nothing
# that can write is reachable unless the dispatch said `apply`. The record is required rather than
# optional, because a run that wrote something and cannot say what it wrote is not evidence.
assert_contains "${backfill_workflow}" 'run: scripts/backfill-runtime-canonicals.sh check'
assert_contains "${backfill_workflow}" 'run: scripts/backfill-runtime-canonicals.sh apply'
assert_contains "${backfill_workflow}" 'environment: plugin-abi-release'
assert_contains "${backfill_workflow}" 'packages: write'
assert_contains "${backfill_workflow}" 'PLUGIN_ABI_BACKFILL_APPLY: "1"'
assert_contains "${backfill_workflow}" 'if-no-files-found: error'
check_step_line=$(grep -Fn 'run: scripts/backfill-runtime-canonicals.sh check' "${backfill_workflow}" | cut -d: -f1)
apply_step_line=$(grep -Fn 'run: scripts/backfill-runtime-canonicals.sh apply' "${backfill_workflow}" | cut -d: -f1)
(( apply_step_line > check_step_line )) || {
  echo 'the backfill can write before it has proved the plan reads the way it claims' >&2
  exit 1
}
# Both write-capable steps are gated, and the acknowledgement is set exactly once.
if [[ $(grep -Fc 'if: ${{ inputs.apply }}' "${backfill_workflow}") != 2 ]]; then
  echo 'the backfill login or write step is not gated on the apply input' >&2
  exit 1
fi
if [[ $(grep -Fc 'PLUGIN_ABI_BACKFILL_APPLY' "${backfill_workflow}") != 1 ]]; then
  echo 'the backfill acknowledgement is set anywhere but on the writing step' >&2
  exit 1
fi

# Three jobs ask whether a revision someone cited is a commit of this checkout, which a depth-one checkout
# answers no to even when the answer should be yes: the offline suite grades the committed backfill plan,
# the backfill job grades its own plan, and the compatibility check dates every published SDK generation by
# the commit its image names. The checkout depth is therefore part of what those jobs can prove, and it
# belongs to exactly the jobs that need it: no other Plugin ABI job resolves a cited commit, so none should
# ask for history it does not use.
assert_contains "${verify_workflow}" 'fetch-depth: 0'
assert_contains "${backfill_workflow}" 'fetch-depth: 0'
if [[ $(grep -cF 'fetch-depth: 0' "${backfill_workflow}") != 1 ]]; then
  echo 'the backfill job must check out with the history its plan gate needs' >&2
  exit 1
fi
if [[ $(grep -cF 'fetch-depth: 0' "${verify_workflow}") != 2 ]]; then
  echo 'exactly the two jobs that resolve cited commits may ask for history in the verification workflow' >&2
  exit 1
fi
# Each depth line has to sit inside the job that needs it, so that a depth asked for somewhere else cannot
# silently stand in for the checkout that does -- and so that a job reading no commits cannot accumulate
# history it would never use. Each pair names a job and the step whose answer depends on that history.
mapfile -t verify_depth_lines < <(grep -Fn 'fetch-depth: 0' "${verify_workflow}" | cut -d: -f1)
for job_step in "offline|run: tests/run.sh" "allocatability|run: scripts/derive-compatibility-sdk.sh check"; do
  job=${job_step%%|*}
  step=${job_step#*|}
  job_line=$(grep -Fn "  ${job}:" "${verify_workflow}" | cut -d: -f1)
  step_line=$(grep -Fn "${step}" "${verify_workflow}" | cut -d: -f1)
  depth_under_job=0
  for depth_line in "${verify_depth_lines[@]}"; do
    (( depth_line > job_line && depth_line < step_line )) && depth_under_job=$((depth_under_job + 1))
  done
  (( depth_under_job == 1 )) || {
    printf 'the %s job checks out without the history its cited commits need\n' "${job}" >&2
    exit 1
  }
done

while IFS= read -r action_reference; do
  revision=${action_reference##*@}
  [[ ${revision} =~ ^[0-9a-f]{40}$ ]] || { printf 'non-immutable action reference: %s\n' "${action_reference}" >&2; exit 1; }
done < <(awk '$1 == "uses:" {print $2}' "${verify_workflow}" "${publish_workflow}" "${backfill_workflow}")

if grep -Eq 'github_api_get|releases/download' scripts/plugin-abi-build.sh scripts/verify-plugin-runtime.sh; then
  echo 'Plugin ABI verification downloads an external plugin' >&2
  exit 1
fi
if grep -Fq 'FROM ${SDK_BASE}' Dockerfile || grep -Fq 'plugin-runtime' Dockerfile; then
  echo 'standard/all Dockerfile was coupled to the Plugin ABI stream' >&2
  exit 1
fi
assert_contains README.md 'rulego-server:v1.0.0-plugin'
if grep -R -Fq 'latest-plugin' -- Dockerfile.plugin-* scripts .github 2>/dev/null; then
  echo 'Plugin ABI stream must not define a mutable latest alias' >&2
  exit 1
fi

echo 'Plugin SDK/runtime static contracts passed'
