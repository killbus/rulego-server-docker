#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

[[ $# == 3 ]] || die 'usage: scripts/verify-plugin-oci.sh <sdk-index@digest> <runtime-index-json> <candidate|release>'
sdk_ref=$1
runtime_refs=$2
mode=$3
[[ ${mode} == candidate || ${mode} == release ]] || die 'verification mode must be candidate or release'
"${script_dir}/plugin-abi.sh" validate "--${mode}"
require_command docker jq sha256sum
expected_hosts=$("${script_dir}/plugin-abi.sh" render ci | jq -c '[.hosts[].id] | sort')
# Hosts the publication gate decided not to write are named here rather than rediscovered. A
# superseded host is satisfied by an earlier contract's digest, so its absence from this release's
# refs is correct; every other absence is a host nobody published and must stay red.
superseded_hosts=${PLUGIN_ABI_SUPERSEDED_HOSTS:-[]}
jq -e --argjson expected_hosts "${expected_hosts}" --argjson superseded "${superseded_hosts}" '
  type == "object" and
  ($superseded | type) == "array" and
  ((keys_unsorted | sort) == ($expected_hosts - $superseded)) and
  all(.[]; type == "string" and test("@sha256:[0-9a-f]{64}$")) and
  (keys_unsorted | length) == (($expected_hosts | length) - ($superseded | length))
' <<<"${runtime_refs}" >/dev/null || die 'runtime indexes must match the locked host variants minus the superseded ones'

mkdir -p "${repository_root}/tmp"
work=$(mktemp -d "${repository_root}/tmp/plugin-oci.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
report=${PLUGIN_ABI_SIZE_REPORT:-${work}/sizes.tsv}
printf 'variant\tarchitecture\tcompressed\tuncompressed\n' >"${report}"
manifest_path=$("${script_dir}/plugin-abi.sh" render ci | jq -er '.manifest_path')
canonical_manifest=$("${script_dir}/plugin-abi.sh" render manifest)

verify_index() {
  local variant=$1
  local ref=$2
  local host_id=${3:-plugin}
  local identity=${variant}
  [[ ${variant} != plugin-runtime ]] || identity=${variant}-${host_id}
  local index=${work}/${identity}-index.json
  local expected_index repository arch child child_ref compressed uncompressed labels expected_child ceiling container copied
  local attestation
  [[ ${ref} =~ @sha256:[0-9a-f]{64}$ ]] || die "index must be addressed by digest: ${ref}"
  repository=${ref%@*}
  docker buildx imagetools inspect "${ref}" --format '{{json .Manifest}}' >"${index}"
  expected_index=$("${script_dir}/plugin-abi.sh" render metadata "${variant}" '' "${host_id}")
  if [[ -n ${PLUGIN_ABI_PACKAGING_SOURCE:-} ]]; then
    expected_index=$(jq -c --arg source "${PLUGIN_ABI_PACKAGING_SOURCE}" '. + {"org.opencontainers.image.source":$source}' <<<"${expected_index}")
  fi
  if [[ -n ${PLUGIN_ABI_PACKAGING_REVISION:-} ]]; then
    expected_index=$(jq -c --arg revision "${PLUGIN_ABI_PACKAGING_REVISION}" \
      '. + {"org.opencontainers.image.revision":$revision}' <<<"${expected_index}")
  fi
  jq -e --argjson expected "${expected_index}" '. as $index |
    (.manifests | map(select(.platform.os == "linux" and (.platform.architecture == "amd64" or .platform.architecture == "arm64")))) as $images |
    (.manifests | map(select(.platform.os == "unknown" and .platform.architecture == "unknown" and .annotations["vnd.docker.reference.type"] == "attestation-manifest"))) as $attestations |
    (.digest | test("^sha256:[0-9a-f]{64}$")) and
    ([$images[] | select(.platform.architecture == "amd64")] | length == 1) and
    ([$images[] | select(.platform.architecture == "arm64")] | length == 1) and
    ([.manifests[] | select(.platform.os != "unknown") | .platform.os + "/" + .platform.architecture] | sort == ["linux/amd64", "linux/arm64"]) and
    ($attestations | length == 2) and
    ($images | all(.digest as $digest | $attestations | any(.annotations["vnd.docker.reference.digest"] == $digest))) and
    ($expected | to_entries | all(.[]; $index.annotations[.key] == .value)) and
    (.annotations | has("io.rulego.abi.platform") | not)
  ' "${index}" >/dev/null || die "${variant} index platform or annotation mismatch"

  while IFS= read -r attestation; do
    docker buildx imagetools inspect "${repository}@${attestation}" --raw
  done < <(jq -r '.manifests[] | select(.platform.os == "unknown" and .annotations["vnd.docker.reference.type"] == "attestation-manifest") | .digest' "${index}") \
    | jq -se '
      length == 2 and all(.[];
        [.layers[]?.annotations["in-toto.io/predicate-type"]] as $predicates |
        any($predicates[]; contains("slsa.dev/provenance")) and
        any($predicates[]; contains("spdx.dev/Document"))
      )
    ' >/dev/null || die "${variant} provenance or SBOM attestation is missing"

  while IFS= read -r arch; do
    child=$(jq -er --arg arch "${arch}" '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest' "${index}")
    child_ref="${repository}@${child}"
    compressed=$(docker buildx imagetools inspect "${child_ref}" --raw | jq -er '[.layers[].size] | add')
    retry_command 4 2 docker pull --platform "linux/${arch}" "${child_ref}" >/dev/null
    uncompressed=$(docker image inspect "${child_ref}" --format '{{.Size}}')
    expected_child=$("${script_dir}/plugin-abi.sh" render metadata "${variant}" "${arch}" "${host_id}")
    if [[ -n ${PLUGIN_ABI_PACKAGING_SOURCE:-} ]]; then
      expected_child=$(jq -c --arg source "${PLUGIN_ABI_PACKAGING_SOURCE}" '. + {"org.opencontainers.image.source":$source}' <<<"${expected_child}")
    fi
    if [[ -n ${PLUGIN_ABI_PACKAGING_REVISION:-} ]]; then
      expected_child=$(jq -c --arg revision "${PLUGIN_ABI_PACKAGING_REVISION}" \
        '. + {"org.opencontainers.image.revision":$revision}' <<<"${expected_child}")
    fi
    labels=$(docker image inspect "${child_ref}" --format '{{json .Config.Labels}}')
    jq -e --argjson expected "${expected_child}" '. as $labels |
      ($expected | to_entries | all(.[]; $labels[.key] == .value)) and
      ($labels | has("io.rulego.abi.platforms") | not)
    ' <<<"${labels}" >/dev/null || die "${variant} ${arch} child-label mismatch"

    container=$(docker create --platform "linux/${arch}" "${child_ref}")
    copied=${work}/${identity}-${arch}-manifest.json
    docker cp "${container}:${manifest_path}" "${copied}"
    docker rm "${container}" >/dev/null
    [[ $(jq -S -c . "${copied}") == "${canonical_manifest}" ]] || die "${variant} ${arch} embedded manifest mismatch"

    ceiling=$("${script_dir}/plugin-abi.sh" render size-limit "${arch}" "${host_id}" |
      jq -ec --arg variant "${variant#plugin-}" '.[$variant]')
    if [[ ${mode} == release ]]; then
      ((compressed <= $(jq -er '.compressed' <<<"${ceiling}"))) || die "${variant} ${arch} compressed size exceeds its ceiling"
      ((uncompressed <= $(jq -er '.uncompressed' <<<"${ceiling}"))) || die "${variant} ${arch} uncompressed size exceeds its ceiling"
    fi
    printf '%s\t%s\t%s\t%s\n' \
      "$(if [[ ${variant} == plugin-runtime ]]; then printf '%s/%s' "${variant}" "${host_id}"; else printf '%s' "${variant}"; fi)" \
      "${arch}" "${compressed}" "${uncompressed}" >>"${report}"
  done < <("${script_dir}/plugin-abi.sh" render matrix | jq -r '.include[].goarch')
}

verify_index plugin-sdk "${sdk_ref}"
while IFS=$'\t' read -r host_id runtime_ref; do
  verify_index plugin-runtime "${runtime_ref}" "${host_id}"
done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"${runtime_refs}")
cat "${report}"
