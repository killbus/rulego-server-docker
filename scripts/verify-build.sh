#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

require_command awk curl diff docker jq ps seq sha256sum

if (($# != 1)) || [[ $1 != amd64 && $1 != arm64 ]]; then
  printf 'Usage: %s <amd64|arm64>\n' "${0##*/}" >&2
  exit 2
fi
architecture=$1

build_dir=${repository_root}/build
[[ -f ${build_dir}/version ]] || die 'build/version is missing; run fetch-release.sh first'
[[ -f ${build_dir}/variant ]] || die 'build/variant is missing; run fetch-release.sh first'
version=$(<"${build_dir}/version")
variant=$(<"${build_dir}/variant")

verification_dir=$(mktemp -d "${TMPDIR:-/tmp}/rulego-verify-build.XXXXXX")
container_id=
local_image=
cleanup() {
  if [[ -n ${container_id} ]]; then
    docker rm --force "${container_id}" >/dev/null 2>&1 || true
  fi
  if [[ -n ${local_image} ]]; then
    docker image rm --force "${local_image}" >/dev/null 2>&1 || true
  fi
  rm -rf -- "${verification_dir}"
}
trap cleanup EXIT

retry_command 4 2 docker buildx inspect --bootstrap >/dev/null

expected_file=${build_dir}/${architecture}/rulego-server.sha256
[[ -f ${expected_file} ]] || die "missing expected executable checksum: ${expected_file}"
expected_sha=$(<"${expected_file}")
[[ ${expected_sha} =~ ^[0-9a-f]{64}$ ]] || die "invalid expected executable checksum for ${architecture}"

exported_rootfs=${verification_dir}/rootfs-${architecture}
mkdir -p "${exported_rootfs}"
retry_command 4 2 docker buildx build \
  --platform "linux/${architecture}" \
  --output "type=local,dest=${exported_rootfs}" \
  "${repository_root}"

image_binary=${exported_rootfs}/app/rulego-server
[[ -f ${image_binary} ]] || die "exported image filesystem has no executable for ${architecture}"
actual_sha=$(sha256_file "${image_binary}")
[[ ${actual_sha} == "${expected_sha}" ]] \
  || die "pre-push image checksum mismatch for ${architecture}: expected ${expected_sha}, got ${actual_sha}"
diff --recursive --brief "${build_dir}/${architecture}/rootfs" "${exported_rootfs}/app" >/dev/null \
  || die "exported image payload differs from the complete verified archive payload for ${architecture}"
log "Verified pre-push image executable SHA-256 for ${architecture}: ${actual_sha}"

[[ -d ${exported_rootfs}/app/data ]] || die "image has no /app/data directory for ${architecture}"
for forbidden_path in \
  bin/sh bin/bash usr/bin/bash usr/bin/cc usr/bin/gcc usr/bin/git \
  usr/bin/make usr/bin/python usr/bin/python3; do
  [[ ! -e ${exported_rootfs}/${forbidden_path} ]] \
    || die "forbidden runtime tool found on ${architecture}: /${forbidden_path}"
done

local_image=rulego-server-verify:${variant}-${architecture}-$$
retry_command 4 2 docker buildx build \
  --platform "linux/${architecture}" \
  --load \
  --tag "${local_image}" \
  "${repository_root}"

configured_user=$(docker image inspect --format '{{.Config.User}}' "${local_image}")
[[ ${configured_user} == '65532:65532' ]] \
  || die "image is not configured for the expected non-root user: ${configured_user}"
image_config=$(docker image inspect --format '{{json .Config}}' "${local_image}")
jq -e '
  .Entrypoint == ["/app/rulego-server"]
  and .Cmd == ["-c", "/app/config.conf"]
  and .WorkingDir == "/app"
  and .ExposedPorts["9090/tcp"] == {}
  and .Volumes["/app/data"] == {}
' <<<"${image_config}" >/dev/null \
  || die "image runtime configuration is invalid for ${architecture}"

container_id=$(docker run \
  --detach \
  --platform "linux/${architecture}" \
  --publish '127.0.0.1::9090' \
  "${local_image}")

host_port=
for _ in $(seq 1 30); do
  port_mapping=$(docker port "${container_id}" 9090/tcp 2>/dev/null | head -n1 || true)
  host_port=${port_mapping##*:}
  if [[ -n ${host_port} ]] && curl --fail --silent --show-error --location \
    --connect-timeout 2 --max-time 4 "http://127.0.0.1:${host_port}/editor/" >/dev/null 2>&1; then
    break
  fi
  if [[ $(docker inspect --format '{{.State.Running}}' "${container_id}") != true ]]; then
    docker logs "${container_id}" >&2 || true
    die "${architecture} smoke-test container exited before becoming ready"
  fi
  sleep 1
done

[[ -n ${host_port} ]] || die "could not resolve published port for ${architecture}"
curl --fail --silent --show-error --location \
  --connect-timeout 2 --max-time 4 "http://127.0.0.1:${host_port}/editor/" >/dev/null \
  || { docker logs "${container_id}" >&2 || true; die "HTTP smoke test failed for ${architecture}"; }
process_pid=$(docker inspect --format '{{.State.Pid}}' "${container_id}")
process_uid=$(ps -o uid= -p "${process_pid}" | awk '{print $1}')
[[ ${process_uid} == 65532 ]] \
  || die "server process is not running as UID 65532 on ${architecture}: ${process_uid}"
log "Passed non-root HTTP smoke test for ${variant} ${version} on ${architecture}"

docker rm --force "${container_id}" >/dev/null
container_id=
docker image rm --force "${local_image}" >/dev/null
local_image=
