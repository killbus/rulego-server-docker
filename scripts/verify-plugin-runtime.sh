#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

require_command docker jq curl readelf sha256sum

runtime_load() {
  local expectation=${1:?load expectation is required}
  local image=${2:?runtime image is required}
  local arch=${3:?architecture is required}
  local plugin=${4:?plugin file is required}
  [[ ${expectation} == load || ${expectation} == reject ]] \
    || die 'load expectation must be load or reject'
  [[ -f ${plugin} ]] || die "plugin not found: ${plugin}"

  local work container volume port response process_pid process_uid process_gid
  mkdir -p "${repository_root}/tmp"
  work=$(mktemp -d "${repository_root}/tmp/plugin-runtime.XXXXXX")
  container="rulego-plugin-${arch}-$$"
  volume="rulego-plugin-data-${arch}-$$"
  trap 'docker rm -f "${container}" >/dev/null 2>&1 || true; docker volume rm -f "${volume}" >/dev/null 2>&1 || true; rm -rf -- "${work}"' RETURN
  mkdir -p "${work}/plugins"
  cp -- "${plugin}" "${work}/plugins/plugin.so"
  docker volume create "${volume}" >/dev/null
  retry_command 4 2 docker pull --platform "linux/${arch}" "${image}" >/dev/null
  docker run -d --platform "linux/${arch}" --name "${container}" -p 127.0.0.1::9090 \
    --mount "type=volume,source=${volume},target=/app/data" \
    --mount "type=bind,source=${work}/plugins,target=/app/data/plugins,readonly" "${image}" >/dev/null
  port=$(docker port "${container}" 9090/tcp | sed -n 's/.*://p' | head -1)
  [[ ${port} =~ ^[0-9]+$ ]] || die 'runtime did not publish port 9090'
  response=${work}/components.json
  for _ in $(seq 1 100); do
    if curl --fail --silent "http://127.0.0.1:${port}/api/v1/components" >"${response}"; then break; fi
    if [[ $(docker inspect -f '{{.State.Running}}' "${container}") != true ]]; then break; fi
    sleep 0.2
  done
  [[ -s ${response} ]] || { docker logs "${container}" >&2; die 'RuleGo component API did not become ready'; }
  process_pid=$(docker inspect --format '{{.State.Pid}}' "${container}")
  process_uid=$(ps -o uid= -p "${process_pid}" | awk '{print $1}')
  process_gid=$(ps -o gid= -p "${process_pid}" | awk '{print $1}')
  [[ ${process_uid} == 65532 && ${process_gid} == 65532 ]] || die 'runtime process identity is not UID/GID 65532:65532'

  if [[ ${expectation} == load ]]; then
    jq -e '.nodes | any(.type == "myPlugins/upper")' "${response}" >/dev/null \
      || { docker logs "${container}" >&2; die 'ABI probe did not register'; }
    if docker logs "${container}" 2>&1 | grep -Eqi 'load plugin=.*error='; then
      die 'runtime logged a plugin load error for the ABI probe'
    fi
    docker rm -f "${container}" >/dev/null
    docker run -d --platform "linux/${arch}" --name "${container}" -p 127.0.0.1::9090 \
      --mount "type=volume,source=${volume},target=/app/data" \
      --mount "type=bind,source=${work}/plugins,target=/app/data/plugins,readonly" "${image}" >/dev/null
    port=$(docker port "${container}" 9090/tcp | sed -n 's/.*://p' | head -1)
    : >"${response}"
    for _ in $(seq 1 100); do
      if curl --fail --silent "http://127.0.0.1:${port}/api/v1/components" >"${response}"; then break; fi
      sleep 0.2
    done
    jq -e '.nodes | any(.type == "myPlugins/upper")' "${response}" >/dev/null \
      || { docker logs "${container}" >&2; die 'ABI probe did not register after runtime restart'; }
  else
    jq -e '(.nodes | any(.type == "myPlugins/upper")) | not' "${response}" >/dev/null \
      || die 'incompatible ABI probe unexpectedly registered'
    docker logs "${container}" >"${work}/runtime.log" 2>&1
    grep -Eqi 'load plugin=.*error=' "${work}/runtime.log" \
      || die 'incompatible ABI probe was not rejected with a loader diagnostic'
  fi
}

runtime_filesystem() {
  local image=${1:?runtime image is required}
  local arch=${2:?architecture is required}
  local manifest_path expected_manifest build_json libc_minimum work container interpreter libc
  manifest_path=$("${script_dir}/plugin-abi.sh" render ci | jq -er '.manifest_path')
  expected_manifest=$("${script_dir}/plugin-abi.sh" render manifest)
  build_json=$("${script_dir}/plugin-abi.sh" render build "${arch}")
  libc_minimum=$(jq -er '.native.minimum_version' <<<"${build_json}")
  mkdir -p "${repository_root}/tmp"
  work=$(mktemp -d "${repository_root}/tmp/plugin-rootfs.XXXXXX")
  container="rulego-rootfs-${arch}-$$"
  trap 'docker rm -f "${container}" >/dev/null 2>&1 || true; rm -rf -- "${work}"' RETURN
  retry_command 4 2 docker pull --platform "linux/${arch}" "${image}" >/dev/null
  container=$(docker create --platform "linux/${arch}" "${image}")
  docker export "${container}" | tar -C "${work}" -xf -

  [[ -x ${work}/app/rulego-server && -f ${work}/app/config.conf && -f ${work}/app/node_pool.json ]]
  [[ -d ${work}/app/data && -f ${work}/app/editor/index.html ]]
  [[ -f ${work}${manifest_path} ]] || die 'runtime ABI manifest is missing'
  [[ $(jq -S -c . "${work}${manifest_path}") == "${expected_manifest}" ]] || die 'runtime ABI manifest differs from the lock'
  [[ -z $(find "${work}/app/data/plugins" -type f -name '*.so' -print 2>/dev/null) ]] || die 'runtime bundles a business plugin'
  if find "${work}" \( -path '*/go/pkg/mod/*' -o -path '*/.cache/go-build/*' -o -path '*/opt/rulego/source/*' \) -print -quit | grep -q .; then
    die 'runtime contains source or Go build cache paths'
  fi
  for forbidden in go gcc g++ cc c++ ld git make bash sh; do
    if find "${work}" -type f -perm /111 -name "${forbidden}" -print -quit | grep -q .; then
      die "runtime contains forbidden executable: ${forbidden}"
    fi
  done

  interpreter=$(readelf -l "${work}/app/rulego-server" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
  [[ -n ${interpreter} && -e ${work}${interpreter} ]] || die 'runtime dynamic loader is missing'
  assert_elf_glibc_max "${work}/app/rulego-server" "${libc_minimum}"
  while IFS= read -r needed; do
    find "${work}" -type f -name "${needed}" -print -quit | grep -q . || die "runtime library is missing: ${needed}"
  done < <(readelf -d "${work}/app/rulego-server" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
  libc=$(find "${work}" -type f -name 'libc.so.6' -print -quit)
  [[ -n ${libc} ]] || die 'runtime glibc is missing'
  readelf --version-info "${libc}" | grep -Fq "GLIBC_${libc_minimum}" \
    || die "runtime glibc does not provide GLIBC_${libc_minimum}"

  [[ $(docker image inspect "${image}" --format '{{.Config.User}}') == 65532:65532 ]]
  [[ $(docker image inspect "${image}" --format '{{.Config.WorkingDir}}') == /app ]]
  [[ $(docker image inspect "${image}" --format '{{json .Config.Entrypoint}}') == '["/app/rulego-server"]' ]]
  [[ $(docker image inspect "${image}" --format '{{json .Config.Cmd}}') == '["-c","/app/config.conf"]' ]]
  docker image inspect "${image}" --format '{{.Size}}'
}

missing_libc() {
  local image=${1:?runtime image is required}
  local arch=${2:?architecture is required}
  local work container imported status
  mkdir -p "${repository_root}/tmp"
  work=$(mktemp -d "${repository_root}/tmp/plugin-no-libc.XXXXXX")
  container="rulego-no-libc-${arch}-$$"
  imported="rulego-no-libc:${arch}-$$"
  trap 'docker rm -f "${container}" >/dev/null 2>&1 || true; docker image rm -f "${imported}" >/dev/null 2>&1 || true; rm -rf -- "${work}"' RETURN
  container=$(docker create --platform "linux/${arch}" "${image}")
  mkdir -p "${work}/root/app"
  docker cp "${container}:/app/rulego-server" "${work}/root/app/rulego-server"
  docker rm "${container}" >/dev/null
  container=
  readelf -l "${work}/root/app/rulego-server" | grep -F 'Requesting program interpreter' >"${work}/interpreter.txt"
  tar -C "${work}/root" -cf - . | docker import --platform "linux/${arch}" - "${imported}" >/dev/null
  set +e
  docker run --rm --platform "linux/${arch}" "${imported}" /app/rulego-server >"${work}/stdout" 2>"${work}/stderr"
  status=$?
  set -e
  ((status != 0)) || die 'host unexpectedly started without its libc closure'
  grep -Eqi 'no such file|not found|failed to open|exec format' "${work}/stderr" \
    || { cat "${work}/stderr" >&2; die 'missing-libc failure had no loader diagnostic'; }
}

case ${1:-} in
  load)
    [[ $# == 4 ]] || die 'usage: verify-plugin-runtime.sh load <image> <arch> <plugin>'
    runtime_load load "$2" "$3" "$4"
    ;;
  reject)
    [[ $# == 4 ]] || die 'usage: verify-plugin-runtime.sh reject <image> <arch> <plugin>'
    runtime_load reject "$2" "$3" "$4"
    ;;
  filesystem)
    [[ $# == 3 ]] || die 'usage: verify-plugin-runtime.sh filesystem <image> <arch>'
    runtime_filesystem "$2" "$3"
    ;;
  missing-libc)
    [[ $# == 3 ]] || die 'usage: verify-plugin-runtime.sh missing-libc <image> <arch>'
    missing_libc "$2" "$3"
    ;;
  *) die 'usage: verify-plugin-runtime.sh <load|reject|filesystem|missing-libc> ...' ;;
esac
