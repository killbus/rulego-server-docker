#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

[[ ${GITHUB_ACTIONS:-} == true ]] || die 'Plugin ABI image builds run only in GitHub Actions'
[[ $# == 1 ]] || die 'usage: scripts/plugin-abi-build.sh <amd64|arm64>'
arch=$1
build_json=$("${script_dir}/plugin-abi.sh" render build "${arch}")
ci_json=$("${script_dir}/plugin-abi.sh" render ci)
require_command docker jq curl readelf sha256sum

platform=$(jq -er '.target.platform' <<<"${build_json}")
sdk_base=$(jq -er '.native.sdk_base' <<<"${build_json}")
runtime_base=$(jq -er '.native.runtime_base' <<<"${build_json}")
manifest_path=$(jq -er '.manifest_path' <<<"${build_json}")
abi_id=$(jq -er '.abi_id' <<<"${build_json}")
lock_digest=$(jq -er '.lock_digest' <<<"${build_json}")
libc_minimum=$(jq -er '.native.minimum_version' <<<"${build_json}")
publish=${PLUGIN_ABI_PUBLISH:-false}
[[ ${publish} == true || ${publish} == false ]] || die 'PLUGIN_ABI_PUBLISH must be true or false'
if [[ ${publish} == true ]]; then
  "${script_dir}/plugin-abi.sh" validate --release
fi

work=${repository_root}/tmp/plugin-abi-${arch}
[[ ${work} == "${repository_root}/tmp/plugin-abi-${arch}" ]] || die 'unsafe Plugin ABI work path'
rm -rf -- "${work}"
mkdir -p "${work}"
export TMPDIR=${work}/tmp
mkdir -p "${TMPDIR}"

registry_name=plugin-abi-registry-${arch}-${GITHUB_RUN_ID:-$$}
trap 'docker rm -f "${registry_name}" >/dev/null 2>&1 || true' EXIT
docker run -d --name "${registry_name}" --network host \
  registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373 >/dev/null

PLUGIN_ABI_TMP_ROOT=${work} \
PLUGIN_ABI_BUILD_ROOT=${work} \
PLUGIN_ABI_GO_IMAGE=${sdk_base} \
  "${script_dir}/prepare-plugin-abi.sh" "${arch}"
context=${work}/plugin-abi

probe_source=${work}/abi-probe
mkdir -p "${probe_source}"
cp -- "${context}/source/testdata/plugin/plugin.go" "${probe_source}/"
cp -- "${context}/source/server/go.sum" "${probe_source}/go.sum"
printf 'module example.com/rulego-abi-probe\n\ngo %s\n\nrequire %s %s\n' \
  "$(jq -er '.go.version' <<<"${build_json}")" \
  "$(jq -er '.rulego_core.module' <<<"${build_json}")" \
  "$(jq -er '.rulego_core.version' <<<"${build_json}")" >"${probe_source}/go.mod"

source_url=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
packaging_revision=${GITHUB_SHA:?GITHUB_SHA is required}
[[ ${packaging_revision} =~ ^[0-9a-f]{40}$ ]] || die 'GITHUB_SHA must be a full lowercase commit revision'

label_args() {
  local variant=$1 label
  IMAGE_LABELS=()
  while IFS= read -r label; do IMAGE_LABELS+=(--label "${label}"); done < <(
    "${script_dir}/plugin-abi.sh" render metadata "${variant}" "${arch}" \
      | jq -r 'to_entries[] | "\(.key)=\(.value)"'
    printf '%s\n' \
      "org.opencontainers.image.source=${source_url}" \
      "org.opencontainers.image.revision=${packaging_revision}" \
      'org.opencontainers.image.licenses=Apache-2.0'
  )
}

inspect_native() {
  local reference=$1 output=$2
  docker buildx imagetools inspect "${reference}" --format '{{json .Manifest}}' >"${output}"
  jq -e --arg arch "${arch}" '
    (.digest | test("^sha256:[0-9a-f]{64}$")) and
    ([.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch)] | length == 1) and
    ([.manifests[] | select(.platform.os == "unknown" and .platform.architecture == "unknown" and
      .annotations["vnd.docker.reference.type"] == "attestation-manifest")] | length == 1)
  ' "${output}" >/dev/null || die "invalid native image index: ${reference}"
}

sdk_repository=localhost:5000/plugin-sdk-${arch}
runtime_repository=localhost:5000/plugin-runtime-${arch}
sdk_staging=''
runtime_staging=''
if [[ ${publish} == true ]]; then
  owner=${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}
  owner=${owner,,}
  sdk_image=$(jq -er '.sdk_image' <<<"${ci_json}")
  runtime_image=$(jq -er '.runtime_image' <<<"${ci_json}")
  runtime_tag_suffix=$(jq -er '.runtime_tag_suffix' <<<"${ci_json}")
  sdk_staging="ghcr.io/${owner}/${sdk_image}:staging-${packaging_revision}-${arch}"
  runtime_staging="ghcr.io/${owner}/${runtime_image}:staging-${packaging_revision}-${arch}${runtime_tag_suffix}"
fi

label_args plugin-sdk
docker buildx build --file "${repository_root}/Dockerfile.plugin-sdk" --platform "${platform}" \
  --build-arg "SDK_BASE=${sdk_base}" --build-arg "ABI_MANIFEST_PATH=${manifest_path}" \
  "${IMAGE_LABELS[@]}" --provenance=mode=max --sbom=true \
  --metadata-file "${work}/sdk-build.json" \
  --output "type=registry,name=${sdk_repository}:candidate" "${context}"
inspect_native "${sdk_repository}:candidate" "${work}/sdk-index.json"
sdk_index=$(jq -er '.digest' "${work}/sdk-index.json")
sdk_child=$(jq -er --arg arch "${arch}" '.manifests[] | select(.platform.os=="linux" and .platform.architecture==$arch) | .digest' "${work}/sdk-index.json")
sdk_ref=${sdk_repository}@${sdk_child}

mkdir -p "${work}/sdk-output"
chmod 0777 "${work}/sdk-output"
docker run --rm --platform "${platform}" \
  --volume "${probe_source}:/workspace:ro" --volume "${work}/sdk-output:/output" \
  "${sdk_ref}" . "/output/sdk-probe-${arch}.so"
jq -e --arg abi "${abi_id}" --arg platform "${platform}" --arg lock "${lock_digest}" \
  '.abi_id==$abi and .platform==$platform and .lock_digest==$lock' \
  "${work}/sdk-output/sdk-probe-${arch}.so.abi.json" >/dev/null
docker run --rm --platform "${platform}" --entrypoint go \
  --volume "${work}/sdk-output:/output:ro" "${sdk_ref}" \
  version -m "/output/sdk-probe-${arch}.so" >"${work}/sdk-probe.buildinfo"
grep -Fq "go$(jq -er '.go.version' <<<"${build_json}")" "${work}/sdk-probe.buildinfo"

runtime_context=${work}/runtime-context
mkdir -p "${runtime_context}/rootfs" "${runtime_context}/manifest"
chmod 0777 "${runtime_context}/rootfs"
docker run --rm --platform "${platform}" --entrypoint /usr/local/bin/build-plugin-host \
  --env RULEGO_EDITOR_SOURCE=/input/editor \
  --volume "${context}/runtime/editor:/input/editor:ro" \
  --volume "${runtime_context}/rootfs:/out/rootfs" "${sdk_ref}"
cp -- "${context}/manifest/plugin-abi.json" "${runtime_context}/manifest/plugin-abi.json"

label_args plugin-runtime
docker buildx build --file "${repository_root}/Dockerfile.plugin-runtime" --platform "${platform}" \
  --build-arg "RUNTIME_BASE=${runtime_base}" --build-arg "ABI_MANIFEST_PATH=${manifest_path}" \
  "${IMAGE_LABELS[@]}" --provenance=mode=max --sbom=true \
  --metadata-file "${work}/runtime-build.json" \
  --output "type=registry,name=${runtime_repository}:candidate" "${runtime_context}"
inspect_native "${runtime_repository}:candidate" "${work}/runtime-index.json"
runtime_index=$(jq -er '.digest' "${work}/runtime-index.json")
runtime_child=$(jq -er --arg arch "${arch}" '.manifests[] | select(.platform.os=="linux" and .platform.architecture==$arch) | .digest' "${work}/runtime-index.json")
runtime_ref=${runtime_repository}@${runtime_child}

assert_elf_glibc_max "${work}/sdk-output/sdk-probe-${arch}.so" "${libc_minimum}"

"${script_dir}/verify-plugin-runtime.sh" filesystem "${runtime_ref}" "${arch}" >"${work}/runtime-uncompressed.txt"
"${script_dir}/verify-plugin-runtime.sh" load "${runtime_ref}" "${arch}" "${work}/sdk-output/sdk-probe-${arch}.so"

cp -- "${work}/sdk-output/sdk-probe-${arch}.so" "${work}/wrong-arch.so"
if [[ ${arch} == amd64 ]]; then
  printf '\267\000' | dd of="${work}/wrong-arch.so" bs=1 seek=18 conv=notrunc status=none
  readelf -h "${work}/wrong-arch.so" | grep -Eq 'Machine:[[:space:]]+AArch64$'
else
  printf '\076\000' | dd of="${work}/wrong-arch.so" bs=1 seek=18 conv=notrunc status=none
  readelf -h "${work}/wrong-arch.so" | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64$'
fi
"${script_dir}/verify-plugin-runtime.sh" reject "${runtime_ref}" "${arch}" "${work}/wrong-arch.so"

mkdir -p "${work}/wrong-abi"
chmod 0777 "${work}/wrong-abi"
# shellcheck disable=SC2016
docker run --rm --platform "${platform}" --entrypoint bash \
  --volume "${probe_source}:/workspace:ro" --volume "${work}/wrong-abi:/output" \
  "${sdk_ref}" -ceu '
    . /opt/rulego/build.env
    mkdir -p /tmp/wrong-abi/home /tmp/wrong-abi/cache
    GOENV="$GOENV" GOTOOLCHAIN="$GOTOOLCHAIN" go -C /tmp/wrong-abi work init /workspace /opt/rulego/source/server
    read -r -a flags <<<"$PLUGIN_FLAGS"
    ldflags=(); [[ -z "$PLUGIN_LDFLAGS" ]] || ldflags=(-ldflags "$PLUGIN_LDFLAGS")
    env HOME=/tmp/wrong-abi/home GOCACHE=/tmp/wrong-abi/cache GOMODCACHE=/go/pkg/mod \
      GOENV="$GOENV" GOTOOLCHAIN="$GOTOOLCHAIN" GOFLAGS="$GOFLAGS" GOEXPERIMENT="$GOEXPERIMENT" \
      GOWORK=/tmp/wrong-abi/go.work CGO_ENABLED="$CGO_ENABLED" GOOS="$GOOS" GOARCH="$GOARCH" \
      CC="$CC" CXX="$CXX" CGO_CFLAGS="$CGO_CFLAGS" CGO_CPPFLAGS="$CGO_CPPFLAGS" \
      CGO_CXXFLAGS="$CGO_CXXFLAGS" CGO_LDFLAGS="$CGO_LDFLAGS" "$TUNING_KEY=$TUNING_VALUE" \
      go -C /workspace build "-buildmode=$PLUGIN_MODE" -gcflags=all=-N "${flags[@]}" "${ldflags[@]}" -o /output/plugin.so .
  '
"${script_dir}/verify-plugin-runtime.sh" reject "${runtime_ref}" "${arch}" "${work}/wrong-abi/plugin.so"
"${script_dir}/verify-plugin-runtime.sh" missing-libc "${runtime_ref}" "${arch}"

verify_child() {
  local variant=$1 ref=$2 expected labels container copied
  retry_command 4 2 docker pull --platform "${platform}" "${ref}" >/dev/null
  labels=$(docker image inspect "${ref}" --format '{{json .Config.Labels}}')
  expected=$("${script_dir}/plugin-abi.sh" render metadata "${variant}" "${arch}" | jq -c \
    --arg source "${source_url}" --arg revision "${packaging_revision}" \
    '. + {"org.opencontainers.image.source":$source,"org.opencontainers.image.revision":$revision,"org.opencontainers.image.licenses":"Apache-2.0"}')
  jq -e --argjson expected "${expected}" '. as $labels | $expected | to_entries | all(.[]; $labels[.key] == .value)' \
    <<<"${labels}" >/dev/null || die "${variant} child labels differ from the lock"
  container=$(docker create --platform "${platform}" "${ref}")
  copied=${work}/${variant}-manifest.json
  docker cp "${container}:${manifest_path}" "${copied}"
  docker rm "${container}" >/dev/null
  [[ $(jq -S -c . "${copied}") == "$("${script_dir}/plugin-abi.sh" render manifest)" ]] \
    || die "${variant} embedded ABI manifest differs from the lock"
  docker buildx imagetools inspect "${ref}" --raw | jq -er '[.layers[].size] | add'
}

sdk_compressed=$(verify_child plugin-sdk "${sdk_ref}")
runtime_compressed=$(verify_child plugin-runtime "${runtime_ref}")
sdk_uncompressed=$(docker image inspect "${sdk_ref}" --format '{{.Size}}')
runtime_uncompressed=$(docker image inspect "${runtime_ref}" --format '{{.Size}}')
if [[ $(jq -er '.release_state' <<<"${ci_json}") == ready ]]; then
  limits=$("${script_dir}/plugin-abi.sh" render size-limit "${arch}")
  ((sdk_compressed <= $(jq -er '.sdk.compressed' <<<"${limits}"))) || die "${arch} SDK compressed image exceeds its ceiling"
  ((sdk_uncompressed <= $(jq -er '.sdk.uncompressed' <<<"${limits}"))) || die "${arch} SDK uncompressed image exceeds its ceiling"
  ((runtime_compressed <= $(jq -er '.runtime.compressed' <<<"${limits}"))) || die "${arch} runtime compressed image exceeds its ceiling"
  ((runtime_uncompressed <= $(jq -er '.runtime.uncompressed' <<<"${limits}"))) || die "${arch} runtime uncompressed image exceeds its ceiling"
fi

if [[ ${publish} == true ]]; then
  retry_command 4 2 docker buildx imagetools create --tag "${sdk_staging}" \
    "${sdk_repository}@${sdk_index}"
  retry_command 4 2 docker buildx imagetools create --tag "${runtime_staging}" \
    "${runtime_repository}@${runtime_index}"
  inspect_native "${sdk_staging}" "${work}/sdk-staging.json"
  inspect_native "${runtime_staging}" "${work}/runtime-staging.json"
  [[ $(jq -er '.digest' "${work}/sdk-staging.json") == "${sdk_index}" ]]
  [[ $(jq -er '.digest' "${work}/runtime-staging.json") == "${runtime_index}" ]]
fi

jq -S -n \
  --arg architecture "${arch}" --arg platform "${platform}" --arg abi_id "${abi_id}" \
  --arg lock_digest "${lock_digest}" --arg packaging_revision "${packaging_revision}" \
  --arg sdk_local "${sdk_repository}" --arg sdk_staging "${sdk_staging}" \
  --arg sdk_index "${sdk_index}" --arg sdk_child "${sdk_child}" \
  --arg runtime_local "${runtime_repository}" --arg runtime_staging "${runtime_staging}" \
  --arg runtime_index "${runtime_index}" --arg runtime_child "${runtime_child}" \
  --argjson sdk_compressed "${sdk_compressed}" --argjson sdk_uncompressed "${sdk_uncompressed}" \
  --argjson runtime_compressed "${runtime_compressed}" --argjson runtime_uncompressed "${runtime_uncompressed}" '
  {architecture:$architecture,platform:$platform,abi_id:$abi_id,lock_digest:$lock_digest,
   packaging_revision:$packaging_revision,
   sdk:{local_repository:$sdk_local,staging_reference:($sdk_staging | if length == 0 then null else . end),index_digest:$sdk_index,
        child_digest:$sdk_child,compressed_size:$sdk_compressed,uncompressed_size:$sdk_uncompressed},
   runtime:{local_repository:$runtime_local,staging_reference:($runtime_staging | if length == 0 then null else . end),index_digest:$runtime_index,
            child_digest:$runtime_child,compressed_size:$runtime_compressed,uncompressed_size:$runtime_uncompressed}}
  ' >"${repository_root}/tmp/plugin-abi-${arch}.json"

log "verified Plugin ABI SDK/runtime for ${platform}; evidence: tmp/plugin-abi-${arch}.json"
