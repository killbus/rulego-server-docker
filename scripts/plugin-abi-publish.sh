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
recipe_id=$("${script_dir}/plugin-abi.sh" render recipe-id)
lock_digest=$("${script_dir}/plugin-abi.sh" render lock-digest)
packaging_revision=${GITHUB_SHA:?GITHUB_SHA is required}
[[ ${packaging_revision} =~ ^[0-9a-f]{40}$ ]] || die 'GITHUB_SHA must be a full lowercase commit revision'
rev12=${packaging_revision:0:12}
source_url=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
owner=${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}
owner=${owner,,}

ci_json=$("${script_dir}/plugin-abi.sh" render ci)
tags=$("${script_dir}/plugin-abi.sh" render tags "${rev12}")
sdk_name=$(jq -er '.sdk' <<<"${tags}")
sdk_repository=ghcr.io/${owner}/${sdk_name%%:*}
sdk_canonical=${sdk_repository}:${sdk_name#*:}
runtime_image=$(jq -er '.runtime_image' <<<"${ci_json}")
runtime_repository=ghcr.io/${owner}/${runtime_image}

arches=()
while IFS= read -r arch; do arches+=("${arch}"); done \
  < <("${script_dir}/plugin-abi.sh" render matrix | jq -r '.include[].goarch')
[[ ${#arches[@]} == 2 ]] || die 'publication requires exactly two locked architectures'

hosts=()
while IFS= read -r host; do hosts+=("${host}"); done < <(jq -r '.hosts[].id' <<<"${ci_json}")
[[ ${#hosts[@]} == 3 ]] || die 'publication requires exactly three locked hosts'

verify_sdk_evidence() {
  local arch=$1 file=$2 expected_staging
  expected_staging="${sdk_repository}:staging-${packaging_revision}-${arch}"
  [[ -f ${file} ]] || die "missing native evidence: ${file}"
  jq -e --arg arch "${arch}" --arg abi "${abi_id}" --arg lock "${lock_digest}" \
    --arg revision "${packaging_revision}" --arg staging "${expected_staging}" '
    .architecture == $arch and .platform == ("linux/" + $arch) and
    .abi_id == $abi and .lock_digest == $lock and .packaging_revision == $revision and
    (.sdk.staging_reference == $staging) and
    (.sdk.index_digest | test("^sha256:[0-9a-f]{64}$")) and
    (.sdk.child_digest | test("^sha256:[0-9a-f]{64}$")) and
    (.sdk.compressed_size | type == "number" and . > 0) and
    (.sdk.uncompressed_size | type == "number" and . > 0)
  ' "${file}" >/dev/null || die "invalid SDK evidence for ${arch}: ${file}"
}

verify_runtime_evidence() {
  local arch=$1 file=$2 host=$3 expected_staging
  expected_staging="${runtime_repository}:staging-${packaging_revision}-${arch}-${host}"
  [[ -f ${file} ]] || die "missing native evidence: ${file}"
  jq -e --arg arch "${arch}" --arg abi "${abi_id}" --arg lock "${lock_digest}" \
    --arg revision "${packaging_revision}" --arg host "${host}" --arg staging "${expected_staging}" '
    .architecture == $arch and .platform == ("linux/" + $arch) and
    .abi_id == $abi and .lock_digest == $lock and .packaging_revision == $revision and
    (.runtime[$host] |
      .host == $host and
      .staging_reference == $staging and
      (.index_digest | test("^sha256:[0-9a-f]{64}$")) and
      (.child_digest | test("^sha256:[0-9a-f]{64}$")) and
      (.compressed_size | type == "number" and . > 0) and
      (.uncompressed_size | type == "number" and . > 0))
  ' "${file}" >/dev/null || die "invalid ${host} evidence for ${arch}: ${file}"
}

index_annotations() {
  local variant=$1 host=${2:-}
  local -a metadata_args=("${variant}")
  [[ -z ${host} ]] || metadata_args+=("" "${host}")
  INDEX_ANNOTATIONS=()
  while IFS= read -r annotation; do INDEX_ANNOTATIONS+=(--annotation "index:${annotation}"); done < <(
    "${script_dir}/plugin-abi.sh" render metadata "${metadata_args[@]}" | jq -r 'to_entries[] | "\(.key)=\(.value)"'
    printf '%s\n' \
      "org.opencontainers.image.source=${source_url}" \
      "org.opencontainers.image.revision=${packaging_revision}" \
      'org.opencontainers.image.licenses=Apache-2.0'
  )
}

create_staging_index() {
  local variant=$1 repository=$2 host=$3
  shift 3
  local suffix='' staging existing status
  [[ -z ${host} ]] || suffix="-${host}"
  staging=${repository}:staging-${packaging_revision}${suffix}
  if existing=$(image_reference_digest "${staging}"); then
    printf '%s@%s\n' "${repository}" "${existing}"
    return
  else
    status=$?
    ((status == 1)) || exit "${status}"
  fi
  index_annotations "${variant}" "${host}"
  retry_command 4 2 docker buildx imagetools create "${INDEX_ANNOTATIONS[@]}" --tag "${staging}" "$@"
  existing=$(image_reference_digest "${staging}") || die "staging index was not published: ${staging}"
  printf '%s@%s\n' "${repository}" "${existing}"
}

evidence_child_digest() {
  local variant=$1 host=$2 arch=$3
  if [[ ${variant} == sdk ]]; then
    jq -er '.sdk.child_digest' "${evidence_dir}/plugin-abi-${arch}.json"
  else
    jq -er --arg host "${host}" '.runtime[$host].child_digest' "${evidence_dir}/plugin-abi-${arch}.json"
  fi
}

verify_index_children() {
  local variant=$1 reference=$2 host=${3:-}
  local label=${variant}
  [[ -z ${host} ]] || label=${variant}-${host}
  verify_exact_image_children "${reference}" \
    "$(evidence_child_digest "${variant}" "${host}" amd64)" \
    "$(evidence_child_digest "${variant}" "${host}" arm64)" \
    "${TMPDIR}/${label}-release-index.json" \
    || die "${label} release index differs from verified native evidence"
}

sdk_sources=()
for arch in "${arches[@]}"; do
  evidence=${evidence_dir}/plugin-abi-${arch}.json
  verify_sdk_evidence "${arch}" "${evidence}"
  sdk_sources+=("$(jq -er '.sdk.staging_reference + "@" + .sdk.index_digest' "${evidence}")")
done
sdk_staging_index=$(create_staging_index plugin-sdk "${sdk_repository}" "" "${sdk_sources[@]}")
verify_index_children sdk "${sdk_staging_index}"

declare -A runtime_staging_by_host=()
for host in "${hosts[@]}"; do
  sources=()
  for arch in "${arches[@]}"; do
    evidence=${evidence_dir}/plugin-abi-${arch}.json
    verify_runtime_evidence "${arch}" "${evidence}" "${host}"
    sources+=("$(jq -er --arg host "${host}" '.runtime[$host].staging_reference + "@" + .runtime[$host].index_digest' "${evidence}")")
  done
  staging_index=$(create_staging_index plugin-runtime "${runtime_repository}" "${host}" "${sources[@]}")
  runtime_staging_by_host[${host}]=${staging_index}
  verify_index_children runtime "${staging_index}" "${host}"
done

sdk_ref=$(publish_immutable_image_tag "${sdk_canonical}" "${sdk_staging_index}")

runtime_record_file=${TMPDIR}/plugin-abi-runtime-release.jsonl
: >"${runtime_record_file}"

for host in "${hosts[@]}"; do
  staging_index=${runtime_staging_by_host[${host}]}
  PLUGIN_ABI_SIZE_REPORT=${TMPDIR}/staging-sizes-${host}.tsv \
  PLUGIN_ABI_PACKAGING_SOURCE=${source_url} \
  PLUGIN_ABI_PACKAGING_REVISION=${packaging_revision} \
    "${script_dir}/verify-plugin-oci.sh" "${sdk_staging_index}" "${staging_index}" release "${host}"

  canonical_tag=$(jq -er --arg host "${host}" '.runtime[] | select(.host == $host) | .canonical' <<<"${tags}")
  alias_tag=$(jq -er --arg host "${host}" '.runtime[] | select(.host == $host) | .alias' <<<"${tags}")
  canonical=${runtime_repository}:${canonical_tag#*:}
  alias=${runtime_repository}:${alias_tag#*:}

  canonical_ref=$(publish_immutable_image_tag "${canonical}" "${staging_index}")
  digest=${canonical_ref##*@}
  alias_ref=$(promote_image_alias "${alias}" "${canonical_ref}")
  alias_digest=${alias_ref##*@}

  # Re-verify the published SDK plus this host's canonical runtime and record
  # the final sizes. This is the artifact the workflow uploads.
  PLUGIN_ABI_SIZE_REPORT=${TMPDIR}/published-sizes-${host}.tsv \
  PLUGIN_ABI_PACKAGING_SOURCE=${source_url} \
  PLUGIN_ABI_PACKAGING_REVISION=${packaging_revision} \
    "${script_dir}/verify-plugin-oci.sh" "${sdk_ref}" "${canonical_ref}" release "${host}"

  jq -S -n --arg host "${host}" --arg canonical "${canonical}@${digest}" \
    --arg alias "${alias}@${alias_digest}" --arg digest "${digest}" '
    {host:$host, canonical:$canonical, alias:$alias, digest:$digest}
  ' >"${TMPDIR}/plugin-abi-runtime-${host}.json"
  jq -c . "${TMPDIR}/plugin-abi-runtime-${host}.json" >>"${runtime_record_file}"
done

# Aggregate the per-host published size reports into the single artifact the
# workflow uploads. The SDK rows are identical across hosts, so keep one copy;
# runtime rows stay host-qualified by the report's own label column.
{
  head -n 1 "${TMPDIR}/published-sizes-${hosts[0]}.tsv"
  for host in "${hosts[@]}"; do
    tail -n +2 "${TMPDIR}/published-sizes-${host}.tsv" | grep -v $'^plugin-sdk\t' || true
  done
  tail -n +2 "${TMPDIR}/published-sizes-${hosts[0]}.tsv" | grep $'^plugin-sdk\t' || true
} >"${TMPDIR}/published-sizes.tsv"
[[ $(head -n 1 "${TMPDIR}/published-sizes.tsv") == $'variant\tarchitecture\tcompressed\tuncompressed' ]] \
  || die 'published size report header is invalid'
[[ $(grep -c $'^plugin-sdk\t' "${TMPDIR}/published-sizes.tsv") == 2 ]] \
  || die 'published size report must contain one SDK row per architecture'

runtime_record=$(jq -S -c -s 'map({key: .host, value: {canonical: .canonical, alias: .alias, digest: .digest}}) | from_entries' "${runtime_record_file}")

jq -S -n --arg abi_id "${abi_id}" --arg recipe_id "${recipe_id}" \
  --arg lock_digest "${lock_digest}" --arg packaging_revision "${packaging_revision}" \
  --arg sdk "${sdk_ref}" --argjson runtime "${runtime_record}" '
  {abi_id:$abi_id, recipe_id:$recipe_id, lock_digest:$lock_digest,
   packaging_revision:$packaging_revision, sdk:$sdk, runtime:$runtime}
  ' >"${TMPDIR}/plugin-abi-release.json"

log "published immutable Plugin ABI SDK and ${#hosts[@]} runtime hosts; record: tmp/plugin-abi-release.json"
