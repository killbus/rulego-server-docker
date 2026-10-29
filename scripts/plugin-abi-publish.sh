#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

[[ ${GITHUB_ACTIONS:-} == true ]] || die 'Plugin ABI publication runs only in GitHub Actions'
[[ ${PLUGIN_ABI_PUBLISH:-} == true ]] || die 'Plugin ABI publication requires PLUGIN_ABI_PUBLISH=true'
[[ $# == 1 ]] || die 'usage: scripts/plugin-abi-publish.sh <evidence-directory>'
evidence_dir=$1
[[ -d ${evidence_dir} ]] || die "evidence directory not found: ${evidence_dir}"
"${script_dir}/plugin-abi.sh" validate --release
require_command docker jq sha256sum

mkdir -p "${repository_root}/tmp"
export TMPDIR=${repository_root}/tmp
abi_id=$("${script_dir}/plugin-abi.sh" render id)
lock_digest=$("${script_dir}/plugin-abi.sh" render lock-digest)
packaging_revision=${GITHUB_SHA:?GITHUB_SHA is required}
[[ ${packaging_revision} =~ ^[0-9a-f]{40}$ ]] || die 'GITHUB_SHA must be a full lowercase commit revision'
source_url=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
owner=${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}
owner=${owner,,}
tags=$("${script_dir}/plugin-abi.sh" render tags)
ci_json=$("${script_dir}/plugin-abi.sh" render ci)
sdk_name=$(jq -er '.sdk' <<<"${tags}")
sdk_repository=ghcr.io/${owner}/${sdk_name%%:*}
runtime_repository=ghcr.io/${owner}/$(jq -er '.runtime_image' <<<"${ci_json}")
sdk_canonical=${sdk_repository}:${sdk_name#*:}

mapfile -t arches < <("${script_dir}/plugin-abi.sh" render matrix | jq -r '.include[].goarch')
[[ ${#arches[@]} == 2 ]] || die 'publication requires exactly two locked architectures'
sdk_sources=()
runtime_sources='{}'

verify_evidence() {
  local arch=$1 file=$2 host_id tag_suffix staging index child expected_staging inspected
  [[ -f ${file} ]] || die "missing native evidence: ${file}"
  jq -e --arg arch "${arch}" --arg abi "${abi_id}" --arg lock "${lock_digest}" \
    --arg revision "${packaging_revision}" --argjson hosts "$(jq -c '[.hosts[].id] | sort' <<<"${ci_json}")" '
    .architecture == $arch and .platform == ("linux/" + $arch) and
    .abi_id == $abi and .lock_digest == $lock and .packaging_revision == $revision and
    (.runtime | keys | sort) == $hosts and
    ([.sdk, .runtime[]] | all(
      (.staging_reference | type == "string" and length > 0) and
      (.index_digest | test("^sha256:[0-9a-f]{64}$")) and
      (.child_digest | test("^sha256:[0-9a-f]{64}$")) and
      (.compressed_size | type == "number" and . > 0) and
      (.uncompressed_size | type == "number" and . > 0)))
  ' "${file}" >/dev/null || die "invalid native evidence: ${file}"

  staging=$(jq -er '.sdk.staging_reference' "${file}")
  index=$(jq -er '.sdk.index_digest' "${file}")
  child=$(jq -er '.sdk.child_digest' "${file}")
  expected_staging=${sdk_repository}:staging-${packaging_revision}-${arch}
  [[ ${staging} == "${expected_staging}" ]] || die "unexpected SDK staging reference for ${arch}"
  inspected=${TMPDIR}/sdk-${arch}-staging.json
  docker buildx imagetools inspect "${staging}@${index}" --format '{{json .Manifest}}' >"${inspected}"
  jq -e --arg index "${index}" --arg child "${child}" --arg arch "${arch}" '
    .digest == $index and
    ([.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch and .digest == $child)] | length == 1) and
    ([.manifests[] | select(.platform.os == "unknown" and .platform.architecture == "unknown" and
      .annotations["vnd.docker.reference.type"] == "attestation-manifest" and
      .annotations["vnd.docker.reference.digest"] == $child)] | length == 1)
  ' "${inspected}" >/dev/null || die "SDK staging image differs from native evidence for ${arch}"

  while IFS=$'\t' read -r host_id tag_suffix; do
    staging=$(jq -er --arg host_id "${host_id}" '.runtime[$host_id].staging_reference' "${file}")
    index=$(jq -er --arg host_id "${host_id}" '.runtime[$host_id].index_digest' "${file}")
    child=$(jq -er --arg host_id "${host_id}" '.runtime[$host_id].child_digest' "${file}")
    expected_staging=${runtime_repository}:staging-${packaging_revision}-${arch}${tag_suffix}
    [[ ${staging} == "${expected_staging}" ]] ||
      die "unexpected ${host_id} runtime staging reference for ${arch}"
    inspected=${TMPDIR}/runtime-${host_id}-${arch}-staging.json
    docker buildx imagetools inspect "${staging}@${index}" --format '{{json .Manifest}}' >"${inspected}"
    jq -e --arg index "${index}" --arg child "${child}" --arg arch "${arch}" '
      .digest == $index and
      ([.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch and .digest == $child)] | length == 1) and
      ([.manifests[] | select(.platform.os == "unknown" and .platform.architecture == "unknown" and
        .annotations["vnd.docker.reference.type"] == "attestation-manifest" and
        .annotations["vnd.docker.reference.digest"] == $child)] | length == 1)
    ' "${inspected}" >/dev/null ||
      die "${host_id} runtime staging image differs from native evidence for ${arch}"
  done < <(jq -r '.hosts[] | [.id, .tag_suffix] | @tsv' <<<"${ci_json}")
}

for arch in "${arches[@]}"; do
  evidence=${evidence_dir}/plugin-abi-${arch}.json
  verify_evidence "${arch}" "${evidence}"
  sdk_sources+=("$(jq -er '.sdk.staging_reference + "@" + .sdk.index_digest' "${evidence}")")
  while IFS= read -r host_id; do
    source_ref=$(jq -er --arg host_id "${host_id}" \
      '.runtime[$host_id].staging_reference + "@" + .runtime[$host_id].index_digest' "${evidence}")
    runtime_sources=$(jq -c --arg host_id "${host_id}" --arg source_ref "${source_ref}" \
      '.[$host_id] = ((.[$host_id] // []) + [$source_ref])' <<<"${runtime_sources}")
  done < <(jq -r '.hosts[].id' <<<"${ci_json}")
done

index_annotations() {
  local variant=$1 host_id=${2:-plugin} annotation
  INDEX_ANNOTATIONS=()
  while IFS= read -r annotation; do INDEX_ANNOTATIONS+=(--annotation "index:${annotation}"); done < <(
    "${script_dir}/plugin-abi.sh" render metadata "${variant}" '' "${host_id}" |
      jq -r 'to_entries[] | "\(.key)=\(.value)"'
    printf '%s\n' \
      "org.opencontainers.image.source=${source_url}" \
      "org.opencontainers.image.revision=${packaging_revision}" \
      'org.opencontainers.image.licenses=Apache-2.0'
  )
}

create_staging_index() {
  local variant=$1 repository=$2 host_id=$3 suffix=$4
  shift 4
  local staging existing status
  staging=${repository}:staging-${packaging_revision}${suffix}
  if existing=$(image_reference_digest "${staging}"); then
    printf '%s@%s\n' "${repository}" "${existing}"
    return
  else
    status=$?
    ((status == 1)) || exit "${status}"
  fi
  index_annotations "${variant}" "${host_id}"
  retry_command 4 2 docker buildx imagetools create "${INDEX_ANNOTATIONS[@]}" --tag "${staging}" "$@"
  existing=$(image_reference_digest "${staging}") || die "staging index was not published: ${staging}"
  printf '%s@%s\n' "${repository}" "${existing}"
}

sdk_staging_index=$(create_staging_index plugin-sdk "${sdk_repository}" plugin '' "${sdk_sources[@]}")
runtime_staging_indexes='{}'
while IFS=$'\t' read -r host_id tag_suffix; do
  mapfile -t host_sources < <(jq -r --arg host_id "${host_id}" '.[$host_id][]' <<<"${runtime_sources}")
  runtime_index=$(create_staging_index plugin-runtime "${runtime_repository}" "${host_id}" \
    "${tag_suffix}" "${host_sources[@]}")
  runtime_staging_indexes=$(jq -c --arg host_id "${host_id}" --arg ref "${runtime_index}" \
    '.[$host_id] = $ref' <<<"${runtime_staging_indexes}")
done < <(jq -r '.hosts[] | [.id, .tag_suffix] | @tsv' <<<"${ci_json}")

verify_index_children() {
  local variant=$1 reference=$2 host_id=${3:-plugin}
  local identity=${variant}
  [[ ${variant} != runtime ]] || identity=${variant}-${host_id}
  local index=${TMPDIR}/${identity}-release-index.json
  local selector=.${variant}
  [[ ${variant} != runtime ]] || selector=".runtime[\"${host_id}\"]"
  verify_exact_image_children "${reference}" \
    "$(jq -er "${selector}.child_digest" "${evidence_dir}/plugin-abi-amd64.json")" \
    "$(jq -er "${selector}.child_digest" "${evidence_dir}/plugin-abi-arm64.json")" \
    "${index}" || die "${identity} release index differs from verified native evidence"
}
verify_index_children sdk "${sdk_staging_index}"
while IFS=$'\t' read -r host_id runtime_index; do
  verify_index_children runtime "${runtime_index}" "${host_id}"
done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"${runtime_staging_indexes}")

PLUGIN_ABI_SIZE_REPORT=${TMPDIR}/staging-sizes.tsv \
PLUGIN_ABI_PACKAGING_SOURCE=${source_url} \
PLUGIN_ABI_PACKAGING_REVISION=${packaging_revision} \
  "${script_dir}/verify-plugin-oci.sh" "${sdk_staging_index}" "${runtime_staging_indexes}" release

# Every canonical tag is probed before the first write so a conflicting tag
# cannot leave a partially published release behind.
canonical_plan=${TMPDIR}/canonical-tags.tsv
: >"${canonical_plan}"
printf '%s\t%s\t%s\n' "${sdk_canonical}" "${sdk_staging_index}" plugin-sdk >>"${canonical_plan}"
while IFS=$'\t' read -r host_id runtime_index; do
  runtime_name=$(jq -er --arg host_id "${host_id}" '.runtime[$host_id]' <<<"${tags}")
  printf '%s\t%s\t%s\n' "${runtime_repository}:${runtime_name#*:}" "${runtime_index}" "runtime-${host_id}" >>"${canonical_plan}"
done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"${runtime_staging_indexes}")
require_immutable_tags_publishable "${canonical_plan}"

sdk_ref=$(publish_immutable_image_tag "${sdk_canonical}" "${sdk_staging_index}")
runtime_refs='{}'
while IFS= read -r host_id; do
  runtime_name=$(jq -er --arg host_id "${host_id}" '.runtime[$host_id]' <<<"${tags}")
  runtime_canonical=${runtime_repository}:${runtime_name#*:}
  runtime_index=$(jq -er --arg host_id "${host_id}" '.[$host_id]' <<<"${runtime_staging_indexes}")
  runtime_ref=$(publish_immutable_image_tag "${runtime_canonical}" "${runtime_index}")
  runtime_refs=$(jq -c --arg host_id "${host_id}" --arg ref "${runtime_ref}" \
    '.[$host_id] = $ref' <<<"${runtime_refs}")
done < <(jq -r '.hosts[].id' <<<"${ci_json}")

PLUGIN_ABI_SIZE_REPORT=${TMPDIR}/published-sizes.tsv \
PLUGIN_ABI_PACKAGING_SOURCE=${source_url} \
PLUGIN_ABI_PACKAGING_REVISION=${packaging_revision} \
  "${script_dir}/verify-plugin-oci.sh" "${sdk_ref}" "${runtime_refs}" release

jq -S -n --arg abi_id "${abi_id}" --arg lock_digest "${lock_digest}" \
  --arg packaging_revision "${packaging_revision}" --arg sdk "${sdk_ref}" --argjson runtime "${runtime_refs}" \
  '{abi_id:$abi_id,lock_digest:$lock_digest,packaging_revision:$packaging_revision,sdk:$sdk,runtime:$runtime}' \
  >"${TMPDIR}/plugin-abi-release.json"
log "published immutable Plugin ABI indexes; record: tmp/plugin-abi-release.json"
