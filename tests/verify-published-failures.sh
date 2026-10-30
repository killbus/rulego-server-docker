#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/rulego-published-test.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT

mkdir -p \
  "${test_root}/project/scripts" \
  "${test_root}/project/build/amd64" \
  "${test_root}/project/build/arm64" \
  "${test_root}/fixtures" \
  "${test_root}/bin"
cp "${repository_root}/scripts/lib.sh" "${repository_root}/scripts/verify-published.sh" \
  "${test_root}/project/scripts/"
printf 'v0.37.0\n' >"${test_root}/project/build/version"
expected_sha=$(printf 'expected binary' | sha256sum | awk '{print $1}')
printf '%s\n' "$expected_sha" >"${test_root}/project/build/amd64/rulego-server.sha256"
printf '%s\n' "$expected_sha" >"${test_root}/project/build/arm64/rulego-server.sha256"

amd64_digest=sha256:$(printf 'a%.0s' {1..64})
arm64_digest=sha256:$(printf 'b%.0s' {1..64})
amd64_attestation=${amd64_digest#sha256:}
arm64_attestation=$(printf 'd%.0s' {1..64})

# Mirrors the index that `docker buildx imagetools create` assembles from two
# native push-by-digest builds: one image plus one attestation manifest per platform.
jq -n \
  --arg amd64 "${amd64_digest}" --arg arm64 "${arm64_digest}" \
  --arg amd64_attestation "sha256:${amd64_attestation}" \
  --arg arm64_attestation "sha256:${arm64_attestation}" '
  {
    mediaType: "application/vnd.oci.image.index.v1+json",
    digest: ("sha256:" + ("f" * 64)),
    manifests: [
      {digest: $amd64, platform: {os: "linux", architecture: "amd64"}},
      {digest: $amd64_attestation, platform: {os: "unknown", architecture: "unknown"},
       annotations: {"vnd.docker.reference.type": "attestation-manifest",
                     "vnd.docker.reference.digest": $amd64}},
      {digest: $arm64, platform: {os: "linux", architecture: "arm64", variant: "v8"}},
      {digest: $arm64_attestation, platform: {os: "unknown", architecture: "unknown"},
       annotations: {"vnd.docker.reference.type": "attestation-manifest",
                     "vnd.docker.reference.digest": $arm64}}
    ]
  }' >"${test_root}/fixtures/index.json"

jq 'del(.manifests[] | select(.platform.architecture == "arm64"))' \
  "${test_root}/fixtures/index.json" >"${test_root}/fixtures/index-missing-arm64.json"
jq 'del(.manifests[] | select(.platform.os == "unknown"))' \
  "${test_root}/fixtures/index.json" >"${test_root}/fixtures/index-without-attestations.json"

cat >"${test_root}/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $1 == buildx && $2 == imagetools && $3 == inspect ]]; then
  reference=$4
  if [[ $* == *--raw* ]]; then
    hex=${reference##*:}
    hex=${hex#sha256:}
    cat "${MOCK_ATTESTATION_DIR}/${hex}.json"
  else
    cat "${MOCK_INDEX_FILE}"
  fi
elif [[ $1 == pull ]]; then
  :
elif [[ $1 == create ]]; then
  printf 'mock-container-id\n'
elif [[ $1 == cp ]]; then
  printf '%s' "${MOCK_BINARY_CONTENT}" >"$3"
elif [[ $1 == rm ]]; then
  :
else
  printf 'unexpected docker invocation:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 64
fi
STUB

cat >"${test_root}/bin/sleep" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
:
STUB
chmod +x "${test_root}/bin/docker" "${test_root}/bin/sleep" \
  "${test_root}/project/scripts/verify-published.sh"

# attest_dir <name> <amd64 predicates...> -- writes one attestation manifest per platform.
make_attestation_dir() {
  local dir=$1
  local amd64_layers=$2
  local arm64_layers=$3
  mkdir -p "${test_root}/attest/${dir}"
  build_attestation "${test_root}/attest/${dir}/${amd64_attestation}.json" "${amd64_layers}"
  build_attestation "${test_root}/attest/${dir}/${arm64_attestation}.json" "${arm64_layers}"
}

build_attestation() {
  local output=$1
  local list=$2
  jq -n --arg list "${list}" '{
    mediaType: "application/vnd.oci.image.manifest.v1+json",
    artifactType: "application/vnd.docker.attestation.manifest.v1+json",
    layers: ($list | split(",") | map({
      annotations: {
        "in-toto.io/predicate-type": (
          if . == "provenance" then "https://slsa.dev/provenance/v1"
          elif . == "sbom" then "https://spdx.dev/Document"
          else . end)
      }}))
  }' >"${output}"
}

make_attestation_dir complete provenance,sbom provenance,sbom
make_attestation_dir without-sbom provenance provenance,sbom

run_case() {
  local mode=$1 index_file=$2 attestation_dir=$3 binary_content=$4 expected=$5
  local status=0
  local output_file=${test_root}/${mode}.github_output
  : >"${output_file}"

  set +e
  (
    cd "${test_root}/project"
    PATH="${test_root}/bin:${PATH}" \
      MOCK_INDEX_FILE="${index_file}" \
      MOCK_ATTESTATION_DIR="${test_root}/attest/${attestation_dir}" \
      MOCK_BINARY_CONTENT="${binary_content}" \
      GITHUB_OUTPUT="${output_file}" \
      REGISTRY_RETRY_ATTEMPTS=2 REGISTRY_RETRY_INITIAL_DELAY=1 \
      REGISTRY_RETRY_MAX_DELAY=1 \
      scripts/verify-published.sh registry.invalid/example:test
  ) >"${test_root}/${mode}.stdout" 2>"${test_root}/${mode}.stderr"
  status=$?
  set -e

  # The output file is the licence scripts/promote-alias.sh needs to move a public name, so every
  # case below asserts what it holds, not only whether the run went red: a failing verification that
  # still reported a digest would authorise the promotion it exists to prevent.
  if [[ -z ${expected} ]]; then
    grep -q "^verified_digest=" "${output_file}" || {
      printf 'a passing verification must report the digest it verified\n' >&2
      exit 1
    }
    # The reported digest must be the one the index actually carried, so a promotion cannot be
    # authorised by a value the script never looked at.
    reported=$(sed 's/^verified_digest=//' "${output_file}")
    expected_digest=$(jq -er .digest "${index_file}")
    [[ ${reported} == "${expected_digest}" ]] || {
      printf 'verified_digest=%s but the index under test holds %s\n' "${reported}" "${expected_digest}" >&2
      exit 1
    }
  else
    [[ ! -s ${output_file} ]] || {
      printf 'a failing verification must authorise nothing, got: %s\n' "$(<"${output_file}")" >&2
      exit 1
    }
  fi

  if [[ -z ${expected} ]]; then
    [[ $status -eq 0 ]] || {
      printf 'expected success for %s, got exit %s\n' "${mode}" "${status}" >&2
      cat "${test_root}/${mode}.stderr" >&2
      exit 1
    }
    return
  fi

  [[ $status -ne 0 ]]
  grep -q "${expected}" "${test_root}/${mode}.stderr"
}

run_case missing-arm64 \
  "${test_root}/fixtures/index-missing-arm64.json" complete 'expected binary' \
  'could not inspect published image after bounded retries'
run_case without-attestations \
  "${test_root}/fixtures/index-without-attestations.json" complete 'expected binary' \
  'published image index is missing its attestation manifests'
run_case without-sbom \
  "${test_root}/fixtures/index.json" without-sbom 'expected binary' \
  'published image has no SBOM attestation for amd64'
run_case tampered \
  "${test_root}/fixtures/index.json" complete 'tampered binary' \
  'published image checksum mismatch for amd64'
run_case complete \
  "${test_root}/fixtures/index.json" complete 'expected binary' ''
grep -q 'Verified SLSA provenance and SBOM attestations for arm64' "${test_root}/complete.stderr"

echo 'missing-platform, missing-attestation, missing-SBOM, executable-mismatch, and success cases passed'
