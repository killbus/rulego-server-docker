#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
cd "${repository_root}"

test_root=$(mktemp -d "${repository_root}/tmp/plugin-build-helper.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/workspace" "${test_root}/host" "${test_root}/output"
printf 'module example.com/plugin\n\ngo 1.25.0\n' >"${test_root}/workspace/go.mod"
printf 'module github.com/rulego/rulego/server\n\ngo 1.25.0\n' >"${test_root}/host/go.mod"
: >"${test_root}/host/go.sum"
printf '{}\n' >"${test_root}/manifest.json"
manifest_digest="sha256:$(sha256sum "${test_root}/manifest.json" | awk '{print $1}')"
mod_digest=$(sha256sum "${test_root}/host/go.mod" | awk '{print $1}')
sum_digest=$(sha256sum "${test_root}/host/go.sum" | awk '{print $1}')

cat >"${test_root}/build.env" <<EOF
ABI_ID=abi-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
LOCK_DIGEST=${manifest_digest}
GO_VERSION=1.25.0
GOOS=linux
GOARCH=amd64
CGO_ENABLED=1
GOENV=off
GOTOOLCHAIN=local
GOFLAGS=-mod=readonly
GOEXPERIMENT=''
CGO_CFLAGS=''
CGO_CPPFLAGS=''
CGO_CXXFLAGS=''
CGO_LDFLAGS=''
TUNING_KEY=GOAMD64
TUNING_VALUE=v1
CC=gcc
CXX=g++
CC_VERSION=12.2.0
LINKER_COMMAND=ld
LINKER_IDENTITY='GNU ld'
LINKER_VERSION=2.40
CORE_MODULE=github.com/rulego/rulego
CORE_VERSION=v1.2.3
PLUGIN_MODE=plugin
PLUGIN_FLAGS=-trimpath\ -buildvcs=false
PLUGIN_LDFLAGS=''
PLUGIN_WORKSPACE=generated-server-and-plugin
SERVER_GO_MOD_SHA256=${mod_digest}
SERVER_GO_SUM_SHA256=${sum_digest}
EOF
printf 'github.com/rulego/rulego\tv1.2.3\tfalse\t\t\th1:core\th1:core-mod\n' >"${test_root}/host-modules.tsv"
printf 'github.com/rulego/rulego/server\t\ttrue\t\t\t\t\n' >>"${test_root}/host-modules.tsv"
printf 'example.com/unrelated\tv1.0.0\tfalse\t\t\th1:unrelated\th1:unrelated-mod\n' >>"${test_root}/host-modules.tsv"
printf 'plugin-only\n' >"${test_root}/mode"

cat >"${test_root}/bin/go" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
fake_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
case "$*" in
  'env GOVERSION') printf 'go1.25.0\n' ;;
  'env GOOS') printf 'linux\n' ;;
  'env GOARCH') printf 'amd64\n' ;;
  -C*' work init '*) : ;;
  'mod download all') : ;;
  list\ -deps*\ -f*)
    printf '%s\n' "$*" >"${fake_root}/dependency-list-invocation"
    printf 'example.com/plugin\n'
    printf 'github.com/rulego/rulego\n'
    if [[ $(cat "${fake_root}/mode") == plugin-only ]]; then
      printf 'example.com/extra\n'
    fi
    ;;
  list\ -m\ -f*' all')
    case $(cat "${fake_root}/mode") in
      plugin-only)
        printf 'example.com/extra\tv0.0.1\tfalse\t\t\th1:extra\th1:extra-mod\n'
        printf 'example.com/plugin\t\ttrue\t\t\t\t\n'
        printf 'example.com/unrelated\tv1.0.0\tfalse\t\t\th1:unrelated\th1:unrelated-mod\n'
        printf 'github.com/rulego/rulego\tv1.2.3\tfalse\t\t\th1:core\th1:core-mod\n'
        printf 'github.com/rulego/rulego/server\t\ttrue\t\t\t\t\n'
        ;;
      unrelated-drift)
        printf 'example.com/plugin\t\ttrue\t\t\t\t\n'
        printf 'example.com/unrelated\tv9.0.0\tfalse\texample.com/fork\tv9.0.0\th1:different\th1:different-mod\n'
        printf 'github.com/rulego/rulego\tv1.2.3\tfalse\t\t\th1:core\th1:core-mod\n'
        printf 'github.com/rulego/rulego/server\t\ttrue\t\t\t\t\n'
        ;;
      content-drift)
        printf 'example.com/plugin\t\ttrue\t\t\t\t\n'
        printf 'github.com/rulego/rulego\tv1.2.3\tfalse\t\t\th1:different\th1:core-mod\n'
        printf 'github.com/rulego/rulego/server\t\ttrue\t\t\t\t\n'
        ;;
      gomod-drift)
        printf 'example.com/plugin\t\ttrue\t\t\t\t\n'
        printf 'github.com/rulego/rulego\tv1.2.3\tfalse\t\t\th1:core\th1:different-mod\n'
        printf 'github.com/rulego/rulego/server\t\ttrue\t\t\t\t\n'
        ;;
      upgrade)
        printf 'example.com/plugin\t\ttrue\t\t\t\t\n'
        printf 'github.com/rulego/rulego\tv1.2.4\tfalse\t\t\th1:core-new\th1:core-mod-new\n'
        printf 'github.com/rulego/rulego/server\t\ttrue\t\t\t\t\n'
        ;;
      replacement)
        printf 'example.com/plugin\t\ttrue\t\t\t\t\n'
        printf 'github.com/rulego/rulego\tv1.2.3\tfalse\texample.com/core\tv1.2.3\th1:core\th1:core-mod\n'
        printf 'github.com/rulego/rulego/server\t\ttrue\t\t\t\t\n'
        ;;
    esac
    ;;
  'mod verify') printf 'all modules verified\n' ;;
  build*)
    printf '%s\n' "$*" >"${fake_root}/build-invocation"
    while (($#)); do
      if [[ $1 == -o ]]; then printf 'plugin-bytes\n' >"$2"; break; fi
      shift
    done
    ;;
  version\ -m*)
    printf '%s\n' "$2"
    printf '\tgo1.25.0\n'
    printf '\tdep\tgithub.com/rulego/rulego\tv1.2.3\n'
    printf '\tbuild\t-buildmode=plugin\n'
    printf '\tbuild\tCGO_ENABLED=1\n'
    printf '\tbuild\tGOARCH=amd64\n'
    ;;
  *) printf 'unexpected fake go invocation: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
chmod +x "${test_root}/bin/go"

cat >"${test_root}/bin/gcc" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -dumpfullversion ]] && printf '12.2.0\n'
EOF
cat >"${test_root}/bin/ld" <<'EOF'
#!/usr/bin/env bash
fake_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
if [[ $1 == --version ]]; then
  if [[ -f ${fake_root}/wrong-linker ]]; then
    printf 'LLD 2.40\n'
  else
    printf 'GNU ld 2.40\n'
  fi
fi
EOF
chmod +x "${test_root}/bin/gcc" "${test_root}/bin/ld"

run_helper() {
  env \
    PATH="${test_root}/bin:${PATH}" \
    RULEGO_ABI_MANIFEST="${test_root}/manifest.json" \
    RULEGO_PLUGIN_SOURCE="${test_root}/workspace" \
    RULEGO_HOST_SOURCE="${test_root}/host" \
    RULEGO_HOST_MODULES="${test_root}/host-modules.tsv" \
    RULEGO_BUILD_ENV="${test_root}/build.env" \
    scripts/rulego-plugin-build . "${test_root}/output/plugin.so"
}

run_helper
[[ -f ${test_root}/output/plugin.so.sha256 && -f ${test_root}/output/plugin.so.abi.json ]]
grep -Fq '"platform": "linux/amd64"' "${test_root}/output/plugin.so.abi.json"
grep -Fq 'list -deps' "${test_root}/dependency-list-invocation"
[[ $(<"${test_root}/dependency-list-invocation") == *' .' ]]
grep -Fq -- '-buildvcs=false' "${test_root}/dependency-list-invocation"
grep -Fq -- '-buildvcs=false' "${test_root}/build-invocation"

printf 'unrelated-drift\n' >"${test_root}/mode"
run_helper

touch "${test_root}/wrong-linker"
if run_helper >"${test_root}/stdout" 2>"${test_root}/stderr"; then
  echo 'expected wrong linker identity to fail' >&2
  exit 1
fi
grep -Fq 'linker identity mismatch' "${test_root}/stderr"
rm -f -- "${test_root}/wrong-linker"

for mode in upgrade replacement content-drift gomod-drift; do
  printf '%s\n' "${mode}" >"${test_root}/mode"
  if run_helper >"${test_root}/stdout" 2>"${test_root}/stderr"; then
    printf 'expected host-module %s to fail\n' "${mode}" >&2
    exit 1
  fi
  grep -Fq 'host-owned module identity mismatch: github.com/rulego/rulego' "${test_root}/stderr"
  grep -Fq '  expected: version=v1.2.3' "${test_root}/stderr"
  grep -Fq '  actual: version=' "${test_root}/stderr"
done

echo 'Plugin SDK helper filters host identities by requested package dependencies'
