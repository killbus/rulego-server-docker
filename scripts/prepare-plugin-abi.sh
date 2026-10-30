#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

[[ $# == 1 ]] || die 'usage: scripts/prepare-plugin-abi.sh <amd64|arm64>'
arch=$1
build_json=$("${script_dir}/plugin-abi.sh" render build "${arch}")
require_command git jq sha256sum tar
if [[ -n ${PLUGIN_ABI_GO_IMAGE:-} ]]; then
  require_command docker
else
  require_command go
fi

revision=$(jq -er '.rulego_server.revision' <<<"${build_json}")
release_version=$(jq -er '.rulego_server.release_version' <<<"${build_json}")
repository=$(jq -er '.rulego_server.repository' <<<"${build_json}")
go_version=$(jq -er '.go.version' <<<"${build_json}")
reproducible_epoch=$(jq -er '.reproducible_epoch' <<<"${build_json}")
manifest_path=$(jq -er '.manifest_path' <<<"${build_json}")
go_mod_sha=$(jq -er '.rulego_server.go_mod_sha256' <<<"${build_json}")
go_sum_sha=$(jq -er '.rulego_server.go_sum_sha256' <<<"${build_json}")
list_sha=$(jq -er '.module_graph.list_sha256' <<<"${build_json}")
graph_sha=$(jq -er '.module_graph.graph_sha256' <<<"${build_json}")
core_module=$(jq -er '.rulego_core.module' <<<"${build_json}")
core_version=$(jq -er '.rulego_core.version' <<<"${build_json}")
cgo_enabled=$(jq -er 'if .go.cgo_enabled then "1" else "0" end' <<<"${build_json}")
goos=$(jq -er '.go.goos' <<<"${build_json}")
host_workspace=$(jq -er '.build.host_workspace' <<<"${build_json}")
tmp_root=${PLUGIN_ABI_TMP_ROOT:-${repository_root}/tmp}
build_root=${PLUGIN_ABI_BUILD_ROOT:-${repository_root}/build}
mkdir -p "${tmp_root}" "${build_root}"
stage=$(mktemp -d "${tmp_root}/plugin-abi-prepare.XXXXXX")
cleanup() {
  chmod -R u+w -- "${stage}" 2>/dev/null || true
  rm -rf -- "${stage}" 2>/dev/null || true
}
trap cleanup EXIT
checkout=${stage}/checkout
context=${stage}/context
# The two staged roots are the only context entries any Plugin ABI image
# copies. Each one holds its payload at the image-relative path with the
# filesystem root as the COPY destination, which is the shape buildkit can
# reproduce: a directory-form COPY into / with no synthetic parent directory.
stage_root=${context}/stage-root
gomodcache_root=${context}/gomodcache-root
sdk_source=${stage_root}/opt/rulego/source
abi_relative=${manifest_path#/}
mkdir -p "${sdk_source}" "${context}/manifest" "${gomodcache_root}/go/pkg/mod" \
  "${stage_root}/usr/local/bin" "${stage_root}/$(dirname -- "${abi_relative}")" \
  "${stage}/gocache" "${stage}/home"
editor_fetcher=${PLUGIN_ABI_EDITOR_FETCHER:-${script_dir}/fetch-plugin-editor.sh}
"${editor_fetcher}" "${context}/runtime/editor"

git init -q "${checkout}"
git -C "${checkout}" remote add origin "${repository}"
retry_command 5 2 git -C "${checkout}" fetch --depth=1 --no-tags origin "${revision}"
actual_revision=$(git -C "${checkout}" rev-parse FETCH_HEAD)
[[ ${actual_revision} == "${revision}" ]] \
  || die "RuleGo revision mismatch: expected ${revision}, found ${actual_revision}"
git -C "${checkout}" checkout -q --detach FETCH_HEAD
[[ -z $(git -C "${checkout}" status --porcelain) ]] || die 'RuleGo checkout is not clean'
retry_command 5 2 git -C "${checkout}" fetch --depth=1 --no-tags origin \
  "refs/tags/${release_version}:refs/tags/${release_version}"
tag_revision=$(git -C "${checkout}" rev-parse "refs/tags/${release_version}^{commit}")
[[ ${tag_revision} == "${revision}" ]] \
  || die "RuleGo release/source mismatch: ${release_version} peels to ${tag_revision}, expected ${revision}"

tar -C "${checkout}" --exclude=.git -cf - . | tar -C "${sdk_source}" -xf -
server_dir=${sdk_source}/server
[[ -f ${server_dir}/go.mod && -f ${server_dir}/go.sum ]] || die 'RuleGo server module is missing'
[[ $(sha256_file "${server_dir}/go.mod") == "${go_mod_sha}" ]] || die 'RuleGo server go.mod digest mismatch'
[[ $(sha256_file "${server_dir}/go.sum") == "${go_sum_sha}" ]] || die 'RuleGo server go.sum digest mismatch'
resolver_dir=${stage}/resolver
mkdir -p "${resolver_dir}"
cp -- "${server_dir}/go.mod" "${server_dir}/go.sum" "${resolver_dir}/"

go_env=(
  "HOME=${stage}/home"
  "TMPDIR=${stage}"
  "GOMODCACHE=${gomodcache_root}/go/pkg/mod"
  "GOCACHE=${stage}/gocache"
  "CGO_ENABLED=${cgo_enabled}"
  "GOOS=${goos}"
  "GOARCH=${arch}"
  "GOWORK=${host_workspace}"
)
while IFS=$'\t' read -r name value; do
  go_env+=("${name}=${value}")
done < <(jq -r '.go.environment | to_entries[] | [.key, .value] | @tsv' <<<"${build_json}")
tuning_key=$(jq -er '.target.tuning | keys[0]' <<<"${build_json}")
tuning_value=$(jq -er '.target.tuning[.target.tuning | keys[0]]' <<<"${build_json}")
go_env+=("${tuning_key}=${tuning_value}")

run_go() {
  local directory=$1
  shift
  if [[ -n ${PLUGIN_ABI_GO_IMAGE:-} ]]; then
    local docker_env=() assignment
    for assignment in "${go_env[@]}"; do docker_env+=(--env "${assignment}"); done
    docker run --rm --platform "linux/${arch}" --user "$(id -u):$(id -g)" \
      --volume "${repository_root}:${repository_root}" --workdir "${directory}" \
      "${docker_env[@]}" "${PLUGIN_ABI_GO_IMAGE}" go "$@"
  else
    (cd "${directory}" && env -i "PATH=${PATH}" "${go_env[@]}" go "$@")
  fi
}

actual_go_version=$(run_go "${resolver_dir}" env GOVERSION)
[[ ${actual_go_version} == "go${go_version}" ]] \
  || die "Go toolchain mismatch: expected go${go_version}, found ${actual_go_version}"

run_go "${resolver_dir}" mod download all
run_go "${resolver_dir}" list -m all | LC_ALL=C sort >"${context}/manifest/module-list.txt"
run_go "${resolver_dir}" mod graph | LC_ALL=C sort >"${context}/manifest/module-graph.txt"
actual_list_sha=$(sha256_file "${context}/manifest/module-list.txt")
actual_graph_sha=$(sha256_file "${context}/manifest/module-graph.txt")
[[ ${actual_list_sha} == "${list_sha}" && ${actual_graph_sha} == "${graph_sha}" ]] \
  || die "RuleGo module graph digest mismatch: list expected=${list_sha} found=${actual_list_sha}; graph expected=${graph_sha} found=${actual_graph_sha}"

run_go "${resolver_dir}" list -m -json all >"${stage}/selected.json"
jq -se 'map(select(.Replace != null)) == []' "${stage}/selected.json" >/dev/null \
  || die 'RuleGo module graph contains an unexpected replacement'
jq -se --arg module "${core_module}" --arg version "${core_version}" \
  'any(.Path == $module and .Version == $version)' "${stage}/selected.json" >/dev/null \
  || die 'RuleGo Core selection does not match the lock'
module_identity_template='{{.Path}}{{"\t"}}{{.Version}}{{"\t"}}{{.Main}}{{"\t"}}{{with .Replace}}{{.Path}}{{end}}{{"\t"}}{{with .Replace}}{{.Version}}{{end}}{{"\t"}}{{.Sum}}{{"\t"}}{{.GoModSum}}'
run_go "${resolver_dir}" list -m -f "${module_identity_template}" all \
  | LC_ALL=C sort >"${context}/manifest/host-modules.tsv"

[[ $(sha256_file "${server_dir}/go.mod") == "${go_mod_sha}" ]] \
  || die 'RuleGo server go.mod changed during module resolution'
[[ $(sha256_file "${server_dir}/go.sum") == "${go_sum_sha}" ]] \
  || die 'RuleGo server go.sum changed during module resolution'

"${script_dir}/plugin-abi.sh" render manifest >"${context}/manifest/plugin-abi.json"
"${script_dir}/plugin-abi.sh" render sdk-env "${arch}" >"${context}/manifest/build.env"
printf '%s\n' "${revision}" >"${context}/manifest/source-revision"
printf '%s\n' "${build_json}" >"${context}/manifest/build-${arch}.json"

# Stage the image payloads at their image-relative paths. The manifest
# directory stays outside the staged roots because only the build driver reads
# it and no image copies it.
abi_manifest=${stage_root}/${abi_relative}
cp -- "${context}/manifest/module-list.txt" "${stage_root}/opt/rulego/module-list.txt"
cp -- "${context}/manifest/host-modules.tsv" "${stage_root}/opt/rulego/host-modules.tsv"
cp -- "${context}/manifest/build.env" "${stage_root}/opt/rulego/build.env"
cp -- "${context}/manifest/plugin-abi.json" "${abi_manifest}"
cp -- "${abi_manifest}" "${stage_root}/abi-manifest.json"
install -m 0755 "${script_dir}/rulego-plugin-build" "${stage_root}/usr/local/bin/rulego-plugin-build"
install -m 0755 "${script_dir}/build-plugin-host" "${stage_root}/usr/local/bin/build-plugin-host"

# The transparency log is a witness of the fetch, not a good that was fetched.
# Which sumdb tiles a download caches is a function of how long the log is
# today, so leaving that subtree in the staged module cache moves a 1 GB layer
# every day even when no module changed: two real CI builds of one head left
# 22 tiles in one run and 15 in the other, while all 136,557 other entries
# matched entry for entry. The log is still consulted online by the download
# above, so verification is not weakened; only its trace stays out of the
# image. Pruning sits at the same boundary as the stamp, after every command
# that resolves modules, so no later resolution can re-open the log behind the
# boundary and leave a witness that neither the stamp nor the probe ever sees.
sumdb_witness=${gomodcache_root}/go/pkg/mod/cache/download/sumdb
rm -rf -- "${sumdb_witness}"
if [[ -e ${sumdb_witness} ]]; then
  die "transparency-log witness survived pruning: ${sumdb_witness}"
fi

# Single source boundary for timestamps: git checkout, the module downloader
# and the editor fetcher all write wall-clock mtimes, and buildkit copies them
# into the layer tar. Stamping here is what makes a rebuild of unchanged
# content produce the same child digest, so the probe below must never be
# dropped or reordered before the image build.
stamp_reproducible_tree "${stage_root}" "${reproducible_epoch}"
stamp_reproducible_tree "${gomodcache_root}" "${reproducible_epoch}"
assert_reproducible_tree "${stage_root}" "${reproducible_epoch}"
assert_reproducible_tree "${gomodcache_root}" "${reproducible_epoch}"

destination=${build_root}/plugin-abi
rm -rf -- "${destination}"
mv -- "${context}" "${destination}"
log "prepared Plugin ABI build context for linux/${arch} at ${destination}"
