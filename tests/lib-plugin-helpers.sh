#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${repository_root}/scripts/lib.sh"

mkdir -p "${repository_root}/tmp"
test_root=$(mktemp -d "${repository_root}/tmp/lib-plugin-helpers.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/safe-source/blobs/sha256"

cat >"${test_root}/bin/readelf" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $1 == --version-info ]]
for version in ${MOCK_GLIBC_VERSIONS}; do
  printf '  Name: GLIBC_%s\n' "${version}"
done
EOF
chmod +x "${test_root}/bin/readelf"

PATH="${test_root}/bin:${PATH}" MOCK_GLIBC_VERSIONS='2.17 2.34' \
  assert_elf_glibc_max "${test_root}/fixture.so" 2.34
if (PATH="${test_root}/bin:${PATH}" MOCK_GLIBC_VERSIONS='2.17 2.36' \
  assert_elf_glibc_max "${test_root}/fixture.so" 2.34) \
  >"${test_root}/stdout" 2>"${test_root}/stderr"; then
  echo 'expected an ELF requiring GLIBC_2.36 to exceed the 2.34 contract' >&2
  exit 1
fi
grep -Fq 'above locked GLIBC_2.34' "${test_root}/stderr"

printf '{}\n' >"${test_root}/safe-source/index.json"
printf 'blob\n' >"${test_root}/safe-source/blobs/sha256/example"
tar -C "${test_root}/safe-source" -cf "${test_root}/safe.tar" .
extract_safe_tar "${test_root}/safe.tar" "${test_root}/safe-output"
cmp "${test_root}/safe-source/index.json" "${test_root}/safe-output/index.json"

python3 - "${test_root}/unsafe.tar" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w") as archive:
    member = tarfile.TarInfo("../escaped")
    payload = b"escape\n"
    member.size = len(payload)
    archive.addfile(member, io.BytesIO(payload))
PY
if extract_safe_tar "${test_root}/unsafe.tar" "${test_root}/unsafe-output" \
  >"${test_root}/stdout" 2>"${test_root}/stderr"; then
  echo 'expected unsafe tar extraction to fail' >&2
  exit 1
fi
[[ ! -e ${test_root}/escaped ]]
grep -Fq 'unsafe tar member' "${test_root}/stderr"

echo 'Plugin ELF boundary and safe tar helpers passed'
