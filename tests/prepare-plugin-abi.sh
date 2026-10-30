#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

mkdir -p "${repository_root}/tmp"
test_root=$(mktemp -d "${repository_root}/tmp/prepare-plugin-abi.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/source/server" "${test_root}/build" "${test_root}/editor"
printf '<html>locked editor</html>\n' >"${test_root}/editor/index.html"

printf 'module github.com/rulego/rulego/server\n\ngo 1.25.0\n' >"${test_root}/source/server/go.mod"
: >"${test_root}/source/server/go.sum"
printf 'config\n' >"${test_root}/source/server/config.conf"
printf '{}\n' >"${test_root}/source/server/node_pool.json"
# The build driver copies the probe plugin out of the source tree, so the fake
# source has to carry it for the context-path check below to mean anything.
mkdir -p "${test_root}/source/testdata/plugin"
printf 'package plugin\n' >"${test_root}/source/testdata/plugin/plugin.go"

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
# Match scripts/plugin-abi.sh canonicalization: the Windows jq build appends a
# carriage return per output line, which would make this fixture derive a
# different abi_id than the validator expects. No-op on the CI (LF) emitter.
new_id="abi-$(jq -S -c '.abi' "${test_root}/lock-with-stale-id.json" | tr -d '\r' | sha256sum | awk '{print $1}')"
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
    PLUGIN_ABI_BUILD_ROOT="${RUN_BUILD_ROOT:-${test_root}/build}" \
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
[[ -f ${output}/stage-root/opt/rulego/source/server/go.mod ]]
[[ -f ${test_root}/resolver-go.sum-after-download ]]
grep -Fqx 'resolver-only mutation' "${test_root}/resolver-go.sum-after-download"
resolver_path=$(<"${test_root}/resolver-path")
[[ ${resolver_path} == ${test_root}/plugin-abi-prepare.*/resolver ]]
[[ $(wc -l <"${test_root}/module-command-paths") == 5 ]]
if grep -Fvxq -- "${resolver_path}" "${test_root}/module-command-paths"; then
  exit 1
fi
cmp -s "${test_root}/source/server/go.mod" "${output}/stage-root/opt/rulego/source/server/go.mod"
cmp -s "${test_root}/source/server/go.sum" "${output}/stage-root/opt/rulego/source/server/go.sum"
[[ $(sha256sum "${output}/stage-root/opt/rulego/source/server/go.mod" | awk '{print $1}') == \
  $(jq -r '.abi.rulego_server.go_mod_sha256' "${test_root}/lock.json") ]]
[[ $(sha256sum "${output}/stage-root/opt/rulego/source/server/go.sum" | awk '{print $1}') == \
  $(jq -r '.abi.rulego_server.go_sum_sha256' "${test_root}/lock.json") ]]
[[ -f ${output}/manifest/plugin-abi.json ]]
[[ -f ${output}/manifest/module-list.txt ]]
[[ -f ${output}/manifest/host-modules.tsv ]]
[[ -f ${output}/runtime/editor/index.html ]]
[[ -x ${output}/stage-root/usr/local/bin/rulego-plugin-build ]]
[[ -x ${output}/stage-root/usr/local/bin/build-plugin-host ]]
[[ -f ${output}/stage-root/abi-manifest.json ]]
[[ -f ${output}/stage-root/usr/share/rulego/plugin-abi.json ]]
cmp -s "${output}/stage-root/abi-manifest.json" "${output}/stage-root/usr/share/rulego/plugin-abi.json"
cmp -s "${output}/manifest/plugin-abi.json" "${output}/stage-root/usr/share/rulego/plugin-abi.json"
# The staged roots are the reproducibility boundary: every entry, including the
# directories that git checkout and the editor fetcher create, must carry the
# locked epoch and canonical modes rather than the state of whoever ran the
# preparation. assert_staged is the shipped probe, not a copy of its logic.
epoch=$(jq -r '.release.reproducible_epoch' "${test_root}/lock.json")
assert_staged() {
  local root=$1
  (
    # shellcheck source=scripts/lib.sh
    source scripts/lib.sh
    assert_reproducible_tree "${root}" "${epoch}"
  )
}
for staged in "${output}/stage-root" "${output}/gomodcache-root"; do
  assert_staged "${staged}"
done
[[ -d ${output}/gomodcache-root/go/pkg/mod ]]

# The build driver only runs inside GitHub Actions, so nothing else proves that
# the context paths it reads exist. Resolving them here turns a layout rename in
# one script into a local failure instead of a native job that dies on cp.
driver=scripts/plugin-abi-build.sh
while IFS= read -r context_path; do
  [[ -e ${output}/${context_path} ]] || {
    printf 'build driver reads a context path that preparation does not produce: %s\n' \
      "${context_path}" >&2
    exit 1
  }
done < <(
  grep -o '\${context}/[A-Za-z0-9._/-]*' "${driver}" |
    sed 's|^\${context}/||' | LC_ALL=C sort -u
)
grep -Fxq 'HOST_ID=plugin' "${output}/manifest/build.env"
grep -Fxq "HOST_TAGS=''" "${output}/manifest/build.env"
jq -e '.abi.build.hosts == [
  {"id":"plugin","tags":[],"tag_suffix":"-plugin"},
  {"id":"ai-plugin","tags":["with_ai"],"tag_suffix":"-ai-plugin"}
]' "${output}/manifest/plugin-abi.json" >/dev/null
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

# Two preparations of the same lock must yield byte-identical context
# metadata. The fake source tree is restamped and rechmodded between the runs,
# because the fetch stub preserves both: without that stimulus the two runs
# would agree for the wrong reason, the same wall-clock second hiding a missing
# normalizer. This is the check that the reproducibility boundary holds; if it
# regresses, every rebuild moves the child digest and the canonical tag probe
# rejects its own re-run.
context_digest() {
  local root=${1:?context root is required}
  LC_ALL=C tar -cf - --sort=name --numeric-owner --owner=0 --group=0 --format=gnu \
    -C "${root}" . | sha256sum | awk '{print $1}'
}

restamp_source() {
  local epoch=$1 mode=$2
  find "${test_root}/source" -depth -exec touch -h -a -m -d "@${epoch}" {} +
  find "${test_root}/source" -type f -exec chmod "${mode}" {} +
  find "${test_root}/editor" -depth -exec touch -h -a -m -d "@${epoch}" {} +
}

first_root=${test_root}/build-first
second_root=${test_root}/build-second
restamp_source 1000000000 0600
RUN_BUILD_ROOT=${first_root} run_prepare >/dev/null
restamp_source 1200000000 0644
RUN_BUILD_ROOT=${second_root} run_prepare >/dev/null

for staged in stage-root gomodcache-root; do
  before=$(context_digest "${first_root}/plugin-abi/${staged}")
  after=$(context_digest "${second_root}/plugin-abi/${staged}")
  [[ ${before} == "${after}" ]] || {
    printf 'prepared %s differs between two runs of the same lock\n' "${staged}" >&2
    diff \
      <(LC_ALL=C find "${first_root}/plugin-abi/${staged}" -printf '%y %m %s %P\n' | LC_ALL=C sort) \
      <(LC_ALL=C find "${second_root}/plugin-abi/${staged}" -printf '%y %m %s %P\n' | LC_ALL=C sort) \
      | head -20 >&2
    exit 1
  }
  for prepared in "${first_root}" "${second_root}"; do
    assert_staged "${prepared}/plugin-abi/${staged}"
  done
done

echo 'Plugin ABI source preparation and atomic failure passed'
