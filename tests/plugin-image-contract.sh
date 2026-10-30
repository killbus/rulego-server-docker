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
assert_contains scripts/lib.sh 'immutable tag already points to a different digest'
assert_contains scripts/plugin-abi-publish.sh 'verify-plugin-oci.sh'
assert_contains scripts/plugin-abi-publish.sh 'expected_staging=${runtime_repository}:staging-${packaging_revision}-${arch}${tag_suffix}'
assert_contains scripts/plugin-abi-publish.sh 'runtime_staging_indexes='
assert_contains scripts/verify-plugin-oci.sh 'render size-limit "${arch}" "${host_id}"'
assert_contains scripts/plugin-abi-build.sh 'dd of="${work}/wrong-arch.so"'
assert_contains scripts/plugin-abi-build.sh '-gcflags=all=-N'

verify_workflow=.github/workflows/plugin-abi.yml
publish_workflow=.github/workflows/plugin-abi-publish.yml
assert_contains "${verify_workflow}" 'run: scripts/plugin-abi-build.sh "${{ matrix.goarch }}"'
assert_contains "${publish_workflow}" 'run: scripts/plugin-abi-build.sh "${{ matrix.goarch }}"'
assert_contains "${publish_workflow}" 'run: scripts/plugin-abi-publish.sh tmp/evidence'
assert_contains "${publish_workflow}" 'environment: plugin-abi-release'
assert_contains "${publish_workflow}" 'packages: write'
if grep -Fq 'packages: write' "${verify_workflow}"; then
  echo 'ordinary Plugin ABI verification requested package-write permission' >&2
  exit 1
fi
if grep -Eq 'docker (build|run|pull|create|image|buildx)|jq[[:space:]]|oras[[:space:]]' "${verify_workflow}" "${publish_workflow}"; then
  echo 'Plugin ABI workflow contains repository business logic' >&2
  exit 1
fi
if grep -Eq 'packaging_correction|packaging-correction|oci\.tar|oras-project' "${verify_workflow}" "${publish_workflow}" README.md plugin-abi.lock scripts/plugin-abi*.sh; then
  echo 'removed candidate-transport or packaging-correction path remains' >&2
  exit 1
fi

while IFS= read -r action_reference; do
  revision=${action_reference##*@}
  [[ ${revision} =~ ^[0-9a-f]{40}$ ]] || { printf 'non-immutable action reference: %s\n' "${action_reference}" >&2; exit 1; }
done < <(awk '$1 == "uses:" {print $2}' "${verify_workflow}" "${publish_workflow}")

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
