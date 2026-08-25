#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

test_root=$(mktemp -d "${repository_root}/tmp/prepare-plugin-abi.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/source/server" "${test_root}/build" "${test_root}/editor"
printf '<html>locked editor</html>\n' >"${test_root}/editor/index.html"

printf 'module github.com/rulego/rulego/server\n\ngo 1.25.0\n' >"${test_root}/source/server/go.mod"
: >"${test_root}/source/server/go.sum"
printf 'config\n' >"${test_root}/source/server/config.conf"
printf '{}\n' >"${test_root}/source/server/node_pool.json"

core_version=$(jq -r '.abi.rulego_core.version' plugin-abi.lock)
revision=$(jq -r '.abi.rulego_server.revision' plugin-abi.lock)
printf 'github.com/rulego/rulego %s\ngithub.com/rulego/rulego/server\n' "${core_version}" >"${test_root}/module-list.txt"
printf 'github.com/rulego/rulego/server github.com/rulego/rulego@%s\n' "${core_version}" >"${test_root}/module-graph.txt"
printf '%s\n' "${core_version}" >"${test_root}/core-version"

jq \
  --arg mod "$(sha256sum "${test_root}/source/server/go.mod" | awk '{print $1}')" \
  --arg sum "$(sha256sum "${test_root}/source/server/go.sum" | awk '{print $1}')" \
  --arg list "$(sha256sum "${test_root}/module-list.txt" | awk '{print $1}')" \
  --arg graph "$(sha256sum "${test_root}/module-graph.txt" | awk '{print $1}')" '
    .abi.rulego_server.go_mod_sha256 = $mod |
    .abi.rulego_server.go_sum_sha256 = $sum |
    .abi.module_graph.list_sha256 = $list |
    .abi.module_graph.graph_sha256 = $graph
  ' plugin-abi.lock >"${test_root}/lock-with-stale-id.json"
new_id="abi-$(jq -S -c '.abi' "${test_root}/lock-with-stale-id.json" | sha256sum | awk '{print $1}')"
jq --arg id "${new_id}" '.abi_id = $id' "${test_root}/lock-with-stale-id.json" >"${test_root}/lock.json"

cat >"${test_root}/bin/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $1 == init ]]; then
  mkdir -p "${@: -1}"
  exit 0
fi
[[ $1 == -C ]]
checkout=$2
shift 2
case $1 in
  remote|checkout|status) exit 0 ;;
  fetch) cp -a "${FAKE_RULEGO_SOURCE}/." "${checkout}/" ;;
  rev-parse)
    if [[ ${2:-} == refs/tags/* ]]; then
      printf '%s\n' "${FAKE_RULEGO_RELEASE_REVISION:-${FAKE_RULEGO_REVISION}}"
    else
      printf '%s\n' "${FAKE_RULEGO_REVISION}"
    fi
    ;;
  *) exit 2 ;;
esac
EOF

cat >"${test_root}/bin/go" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
fake_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
core_version=$(cat "${fake_root}/core-version")
case "$*" in
  'mod download all'|'list -m all'|'mod graph'|'list -m -json all'|list\ -m\ -f*' all')
    printf '%s\n' "$PWD" >>"${fake_root}/module-command-paths"
    ;;
esac
case "$*" in
  'env GOVERSION') printf 'go1.25.0\n' ;;
  'mod download all')
    printf 'resolver-only mutation\n' >>go.sum
    printf '%s\n' "$PWD" >"${fake_root}/resolver-path"
    cp -- go.sum "${fake_root}/resolver-go.sum-after-download"
    ;;
  'list -m all') cat "${fake_root}/module-list.txt" ;;
  'mod graph') cat "${fake_root}/module-graph.txt" ;;
  'list -m -json all')
    printf '{"Path":"github.com/rulego/rulego/server","Main":true}\n'
    printf '{"Path":"github.com/rulego/rulego","Version":"%s"}\n' "${core_version}"
    ;;
  list\ -m\ -f*' all')
    printf 'github.com/rulego/rulego\t%s\tfalse\t\t\th1:module\th1:gomod\n' "${core_version}"
    printf 'github.com/rulego/rulego/server\t\ttrue\t\t\t\t\n'
    ;;
  *) printf 'unexpected fake go invocation: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
chmod +x "${test_root}/bin/git" "${test_root}/bin/go"
cat >"${test_root}/bin/fetch-editor" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p "$1"
cp -a -- "${FAKE_EDITOR_SOURCE}/." "$1/"
EOF
chmod +x "${test_root}/bin/fetch-editor"

run_prepare() {
  env \
    PATH="${test_root}/bin:${PATH}" \
    PLUGIN_ABI_LOCK="${RUN_LOCK:-${test_root}/lock.json}" \
    PLUGIN_ABI_BUILD_ROOT="${test_root}/build" \
    PLUGIN_ABI_TMP_ROOT="${test_root}" \
    PLUGIN_ABI_EDITOR_FETCHER="${test_root}/bin/fetch-editor" \
    FAKE_EDITOR_SOURCE="${test_root}/editor" \
    FAKE_RULEGO_SOURCE="${test_root}/source" \
    FAKE_RULEGO_REVISION="${RUN_REVISION:-${revision}}" \
    FAKE_RULEGO_RELEASE_REVISION="${RUN_RELEASE_REVISION:-${revision}}" \
    scripts/prepare-plugin-abi.sh amd64
}

run_prepare >/dev/null
output=${test_root}/build/plugin-abi
[[ -f ${output}/source/server/go.mod ]]
[[ -f ${test_root}/resolver-go.sum-after-download ]]
grep -Fqx 'resolver-only mutation' "${test_root}/resolver-go.sum-after-download"
resolver_path=$(<"${test_root}/resolver-path")
[[ ${resolver_path} == ${test_root}/plugin-abi-prepare.*/resolver ]]
[[ $(wc -l <"${test_root}/module-command-paths") == 5 ]]
if grep -Fvxq -- "${resolver_path}" "${test_root}/module-command-paths"; then
  exit 1
fi
cmp -s "${test_root}/source/server/go.mod" "${output}/source/server/go.mod"
cmp -s "${test_root}/source/server/go.sum" "${output}/source/server/go.sum"
[[ $(sha256sum "${output}/source/server/go.mod" | awk '{print $1}') == \
  $(jq -r '.abi.rulego_server.go_mod_sha256' "${test_root}/lock.json") ]]
[[ $(sha256sum "${output}/source/server/go.sum" | awk '{print $1}') == \
  $(jq -r '.abi.rulego_server.go_sum_sha256' "${test_root}/lock.json") ]]
[[ -f ${output}/manifest/plugin-abi.json ]]
[[ -f ${output}/manifest/module-list.txt ]]
[[ -f ${output}/manifest/host-modules.tsv ]]
[[ -f ${output}/runtime/editor/index.html ]]
[[ -x ${output}/rulego-plugin-build && -x ${output}/build-plugin-host ]]
cmp -s "${test_root}/module-list.txt" "${output}/manifest/module-list.txt"
grep -Fqx $'github.com/rulego/rulego\t'"${core_version}"$'\tfalse\t\t\th1:module\th1:gomod' \
  "${output}/manifest/host-modules.tsv"

printf 'preserve\n' >"${output}/sentinel"
expect_atomic_failure() {
  local description=$1
  shift
  if "$@" >"${test_root}/stdout" 2>"${test_root}/stderr"; then
    printf 'expected preparation failure: %s\n' "${description}" >&2
    exit 1
  fi
  [[ $(cat "${output}/sentinel") == preserve ]]
}

run_bad_revision() { RUN_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_prepare; }
expect_atomic_failure 'revision mismatch' run_bad_revision

run_bad_release() { RUN_RELEASE_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_prepare; }
expect_atomic_failure 'release/source mismatch' run_bad_release

cp "${test_root}/source/server/go.mod" "${test_root}/go.mod.good"
printf '\n// changed\n' >>"${test_root}/source/server/go.mod"
expect_atomic_failure 'go.mod digest mismatch' run_prepare
mv "${test_root}/go.mod.good" "${test_root}/source/server/go.mod"

cp "${test_root}/module-list.txt" "${test_root}/module-list.good"
printf 'example.com/unlocked v1.0.0\n' >>"${test_root}/module-list.txt"
expect_atomic_failure 'module-list mismatch' run_prepare
mv "${test_root}/module-list.good" "${test_root}/module-list.txt"

jq '.abi.module_graph.graph_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  "${test_root}/lock.json" >"${test_root}/bad-stale.json"
bad_id="abi-$(jq -S -c '.abi' "${test_root}/bad-stale.json" | sha256sum | awk '{print $1}')"
jq --arg id "${bad_id}" '.abi_id = $id' "${test_root}/bad-stale.json" >"${test_root}/bad.json"
run_bad_lock() { RUN_LOCK="${test_root}/bad.json" run_prepare; }
expect_atomic_failure 'module-graph mismatch' run_bad_lock

echo 'Plugin ABI source preparation and atomic failure passed'
