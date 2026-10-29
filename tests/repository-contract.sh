#!/usr/bin/env bash
# shellcheck disable=SC2016

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

assert_contains() {
  local file=$1
  local text=$2
  grep -Fq -- "${text}" "${file}" || {
    printf 'missing required contract in %s: %s\n' "${file}" "${text}" >&2
    exit 1
  }
}

assert_contains Dockerfile 'FROM gcr.io/distroless/static-debian13:nonroot@sha256:1c2c046bc09ed40fad370b599a0b1ae7987f55b01e247cf27a7c27cd97e5bbc7'
assert_contains Dockerfile 'COPY --chown=65532:65532 build/${TARGETARCH}/rootfs/ /app/'
assert_contains Dockerfile 'WORKDIR /app'
assert_contains Dockerfile 'USER 65532:65532'
assert_contains Dockerfile 'EXPOSE 9090'
assert_contains Dockerfile 'VOLUME ["/app/data"]'
assert_contains Dockerfile 'ENTRYPOINT ["/app/rulego-server"]'
assert_contains Dockerfile 'CMD ["-c", "/app/config.conf"]'

workflow=.github/workflows/publish.yml
assert_contains "${workflow}" 'cron: "17 4 * * *"'
assert_contains "${workflow}" 'workflow_dispatch:'
assert_contains "${workflow}" 'contents: read'
assert_contains "${workflow}" 'packages: write'
assert_contains "${workflow}" 'runner: ubuntu-24.04-arm'
assert_contains "${workflow}" 'platforms: ${{ matrix.platform }}'
assert_contains "${workflow}" 'push-by-digest=true'
assert_contains "${workflow}" 'docker buildx imagetools create'
assert_contains "${workflow}" 'args+=(--annotation "$annotation")'
assert_contains "${workflow}" 'password: ${{ secrets.GITHUB_TOKEN }}'
assert_contains "${workflow}" 'DOCKER_METADATA_ANNOTATIONS_LEVELS: manifest,index'
assert_contains "${workflow}" 'type=raw,value=${{ needs.resolve.outputs.version }}${{ matrix.tag_suffix }}'
assert_contains "${workflow}" "type=raw,value=\${{ matrix.moving_tag }},enable=\${{ needs.resolve.outputs.is_latest == 'true' }}"
assert_contains "${workflow}" 'if [[ $moving_digest != "$version_digest" ]]; then all_complete=false; fi'
assert_contains "${workflow}" 'provenance: mode=max'
assert_contains "${workflow}" 'sbom: true'
assert_contains "${workflow}" "uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
if grep -Fq 'docker/setup-qemu-action' "${workflow}"; then
  echo 'publish workflow must use native architecture runners instead of QEMU' >&2
  exit 1
fi
assert_contains "${workflow}" "uses: docker/setup-buildx-action@37fe631027851001ddb9b187196cc803df7f5f0e"
assert_contains "${workflow}" "uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f"
assert_contains "${workflow}" "uses: docker/metadata-action@dc802804100637a589fabce1cb79ff13a1411302"
assert_contains "${workflow}" "uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a"
assert_contains "${workflow}" "uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
assert_contains "${workflow}" "uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093"

while IFS= read -r action_reference; do
  action_revision=${action_reference##*@}
  [[ ${action_revision} =~ ^[0-9a-f]{40}$ ]] || {
    printf 'workflow contains a non-immutable action reference: %s\n' "${action_reference}" >&2
    exit 1
  }
done < <(awk '$1 == "uses:" {print $2}' "${workflow}")

assert_contains README.md '`vX.Y.Z-all`'
assert_contains README.md '`latest-all`'
assert_contains README.md '`rulego-server-all-linux-arm64.tar.gz`'
assert_contains README.md 'bounded exponential backoff'

echo 'repository image and workflow contracts passed'
