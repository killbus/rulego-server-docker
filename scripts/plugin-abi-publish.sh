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
abi_manifest_digest=$("${script_dir}/plugin-abi.sh" render manifest-digest)
packaging_revision=${GITHUB_SHA:?GITHUB_SHA is required}
[[ ${packaging_revision} =~ ^[0-9a-f]{40}$ ]] || die 'GITHUB_SHA must be a full lowercase commit revision'
# `packaging_revision` qualifies staging tag names and the release record only. It is deliberately
# absent from index annotations and image labels: a per-commit value there moves a digest on every
# build, so a canonical tag could never compare equal to its own content and could not be republished
# without reading as a conflict. Which commit packaged a release stays in the SLSA attestation, which
# buildx writes per invocation anyway.
owner=${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}
owner=${owner,,}
# The canonical runtime name is a per-build name, and this build is the one it names. The same value
# already qualifies staging tag names and the release record, and it is still kept out of image bytes:
# that is what lets a rebuild of an unchanged contract compare equal to its own content.
export PLUGIN_ABI_NAME_REVISION=${packaging_revision}
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
  local arch=$1 file=$2 host_id staging index child expected_staging inspected
  [[ -f ${file} ]] || die "missing native evidence: ${file}"
  jq -e --arg arch "${arch}" --arg abi "${abi_id}" --arg lock "${lock_digest}" \
    --arg manifest "${abi_manifest_digest}" \
    --arg revision "${packaging_revision}" --argjson hosts "$(jq -c '[.hosts[].id] | sort' <<<"${ci_json}")" '
    .architecture == $arch and .platform == ("linux/" + $arch) and
    .abi_id == $abi and .lock_digest == $lock and
    .abi_manifest_digest == $manifest and .packaging_revision == $revision and
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

  while IFS= read -r host_id; do
    staging=$(jq -er --arg host_id "${host_id}" '.runtime[$host_id].staging_reference' "${file}")
    index=$(jq -er --arg host_id "${host_id}" '.runtime[$host_id].index_digest' "${file}")
    child=$(jq -er --arg host_id "${host_id}" '.runtime[$host_id].child_digest' "${file}")
    expected_staging=${runtime_repository}:staging-${packaging_revision}-${arch}-${host_id}
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
  done < <(jq -r '.hosts[].id' <<<"${ci_json}")
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
  local variant=$1 host_id=${2:-} annotation
  local -a args=("${variant}")
  [[ -z ${host_id} ]] || args+=("" "${host_id}")
  INDEX_ANNOTATIONS=()
  while IFS= read -r annotation; do INDEX_ANNOTATIONS+=(--annotation "index:${annotation}"); done < <(
    "${script_dir}/plugin-abi.sh" render metadata "${args[@]}" |
      jq -r 'to_entries[] | "\(.key)=\(.value)"'
  )
}

create_staging_index() {
  local variant=$1 repository=$2 host_id=$3
  shift 3
  local staging existing status
  local suffix=''
  [[ -z ${host_id} ]] || suffix="-${host_id}"
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

sdk_staging_index=$(create_staging_index plugin-sdk "${sdk_repository}" "" "${sdk_sources[@]}")
runtime_staging_indexes='{}'
while IFS= read -r host_id; do
  mapfile -t host_sources < <(jq -r --arg host_id "${host_id}" '.[$host_id][]' <<<"${runtime_sources}")
  runtime_index=$(create_staging_index plugin-runtime "${runtime_repository}" "${host_id}" \
    "${host_sources[@]}")
  runtime_staging_indexes=$(jq -c --arg host_id "${host_id}" --arg ref "${runtime_index}" \
    '.[$host_id] = $ref' <<<"${runtime_staging_indexes}")
done < <(jq -r '.hosts[].id' <<<"${ci_json}")

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
  "${script_dir}/verify-plugin-oci.sh" "${sdk_staging_index}" "${runtime_staging_indexes}" release

# Every canonical tag is probed before the first write so a conflicting tag
# cannot leave a partially published release behind.
canonical_plan=${TMPDIR}/canonical-tags.tsv
: >"${canonical_plan}"

# The child digests are taken from the native build evidence rather than from the staging indexes
# about to be published, because the evidence is what the per-architecture runners produced and
# what `verify_index_children` already holds those indexes against. A plan built from the new index
# digest could only ever ask the registry to compare two things that differ by design.
plan_children() {
  local selector=$1
  printf '%s\t%s\n' \
    "$(jq -er "${selector}.child_digest" "${evidence_dir}/plugin-abi-amd64.json")" \
    "$(jq -er "${selector}.child_digest" "${evidence_dir}/plugin-abi-arm64.json")"
}

# The plan is a set of first-writer promises, so it carries canonical names only. An alias moves by
# design, and a plan line holding a moving name would make the next verified build refuse to publish
# because the previous one had written that name.
while IFS=$'\t' read -r host_id canonical_name alias_name; do
  [[ ${canonical_name} != "${alias_name}" ]] ||
    die "canonical and alias runtime names are identical for ${host_id}: ${canonical_name}"
done < <(jq -r '.runtime | to_entries[] | [.key, .value.canonical, .value.alias] | @tsv' <<<"${tags}")

printf '%s\t%s\t%s\t%s\n' "${sdk_canonical}" "${sdk_staging_index}" plugin-sdk \
  "$(plan_children '.sdk')" >>"${canonical_plan}"
while IFS=$'\t' read -r host_id runtime_index; do
  runtime_name=$(jq -er --arg host_id "${host_id}" '.runtime[$host_id].canonical' <<<"${tags}")
  printf '%s\t%s\t%s\t%s\n' "${runtime_repository}:${runtime_name#*:}" "${runtime_index}" \
    "runtime-${host_id}" "$(plan_children ".runtime[\"${host_id}\"]")" >>"${canonical_plan}"
done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"${runtime_staging_indexes}")
# The plan's size is checked against the lock, not against this render: a canonical runtime name that
# came out null would otherwise look like a smaller batch. `PLUGIN_ABI_NAME_REVISION=none` is the
# pre-build state and is never legal here, where names are about to be written.
require_canonical_plan_lines "${canonical_plan}" "$(jq -r '.hosts | length' <<<"${ci_json}")"

# The gate classifies every canonical name before the first write. Only a `superseded` runtime
# host is left alone: an earlier contract holds that name, and its digest still answers to it.
gate_decisions=$(require_immutable_tags_publishable "${canonical_plan}")
superseded_hosts=$(canonical_superseded_hosts "${gate_decisions}")

# The SDK name carries this contract's identity, so nothing else can hold it legitimately. If the
# gate ever reads it as superseded, writing anyway would publish a release whose own record cannot
# name its SDK, and skipping it would do the same more quietly. Refuse before the first write.
canonical_sdk_superseded "${gate_decisions}" ||
  die 'the SDK canonical tag reads as superseded; a release without its SDK is not publishable'

IFS=$'\t' read -r sdk_amd64_child sdk_arm64_child <<<"$(plan_children '.sdk')"
sdk_ref=$(publish_immutable_image_tag "${sdk_canonical}" "${sdk_staging_index}" \
  "${sdk_amd64_child}" "${sdk_arm64_child}")
runtime_refs='{}'
while IFS= read -r host_id; do
  if jq -e --arg host "${host_id}" 'index($host) != null' <<<"${superseded_hosts}" >/dev/null; then
    log "skipping canonical write for ${host_id}: held by the superseded contract"
    continue
  fi
  runtime_name=$(jq -er --arg host_id "${host_id}" '.runtime[$host_id].canonical' <<<"${tags}")
  runtime_canonical=${runtime_repository}:${runtime_name#*:}
  runtime_index=$(jq -er --arg host_id "${host_id}" '.[$host_id]' <<<"${runtime_staging_indexes}")
  IFS=$'\t' read -r host_amd64_child host_arm64_child <<<"$(plan_children ".runtime[\"${host_id}\"]")"
  runtime_ref=$(publish_immutable_image_tag "${runtime_canonical}" "${runtime_index}" \
    "${host_amd64_child}" "${host_arm64_child}")
  runtime_refs=$(jq -c --arg host_id "${host_id}" --arg ref "${runtime_ref}" \
    '.[$host_id] = $ref' <<<"${runtime_refs}")
done < <(jq -r '.hosts[].id' <<<"${ci_json}")

PLUGIN_ABI_SIZE_REPORT=${TMPDIR}/published-sizes.tsv \
  PLUGIN_ABI_SUPERSEDED_HOSTS="${superseded_hosts}" \
  "${script_dir}/verify-plugin-oci.sh" "${sdk_ref}" "${runtime_refs}" release

# The aliases are recorded as names, not as facts about the registry: writing them is a later step
# that re-reads the registry for itself. A promotion step that had to rebuild these names from the
# lock would be a second naming function, and the two could disagree without anything noticing.
runtime_aliases=$(jq -c --arg repository "${runtime_repository}" '
  .runtime | map_values($repository + ":" + (.alias | split(":")[1]))' <<<"${tags}")
jq -S -n --arg abi_id "${abi_id}" --arg recipe_id "$("${script_dir}/plugin-abi.sh" render recipe-id)" \
  --arg lock_digest "${lock_digest}" \
  --arg abi_manifest_digest "${abi_manifest_digest}" \
  --arg packaging_revision "${packaging_revision}" --arg sdk "${sdk_ref}" --argjson runtime "${runtime_refs}" \
  --argjson runtime_aliases "${runtime_aliases}" \
  --argjson superseded "${superseded_hosts}" \
  '{abi_id:$abi_id,recipe_id:$recipe_id,lock_digest:$lock_digest,abi_manifest_digest:$abi_manifest_digest,
    packaging_revision:$packaging_revision,sdk:$sdk,
    runtime:$runtime,runtime_aliases:$runtime_aliases,superseded_hosts:$superseded}' \
  >"${TMPDIR}/plugin-abi-release.json"
log "published immutable Plugin ABI indexes; record: tmp/plugin-abi-release.json"
