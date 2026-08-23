#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

require_command curl dirname jq mkdir mv

requested_version=${1:-}
if [[ -n ${requested_version} ]]; then
  validate_version "${requested_version}"
fi

temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/rulego-resolve.XXXXXX")
trap 'rm -rf -- "${temporary_dir}"' EXIT

latest_json=${temporary_dir}/latest.json
github_api_get \
  "${latest_json}" \
  'https://api.github.com/repos/rulego/rulego/releases/latest'

latest_version=$(jq -er '
  select(.draft == false and .prerelease == false)
  | .tag_name
' "${latest_json}") || die 'GitHub latest release response is not a stable release'
validate_version "${latest_version}"

if [[ -z ${requested_version} ]]; then
  selected_version=${latest_version}
  selected_json=${latest_json}
elif [[ ${requested_version} == "${latest_version}" ]]; then
  selected_version=${requested_version}
  selected_json=${latest_json}
else
  selected_version=${requested_version}
  selected_json=${temporary_dir}/selected.json
  github_api_get \
    "${selected_json}" \
    "https://api.github.com/repos/rulego/rulego/releases/tags/${selected_version}"
fi

jq -e --arg version "${selected_version}" '
  .tag_name == $version
  and .draft == false
  and .prerelease == false
' "${selected_json}" >/dev/null || die "release is missing, draft, or prerelease: ${selected_version}"

is_latest=false
if [[ ${selected_version} == "${latest_version}" ]]; then
  is_latest=true
fi

jq -n \
  --arg version "${selected_version}" \
  --arg latest_version "${latest_version}" \
  --argjson is_latest "${is_latest}" \
  '{version: $version, latest_version: $latest_version, is_latest: $is_latest}'
