#!/usr/bin/env bash
#
# Move each runtime alias onto the canonical build this release just verified.
#
# This is the second half of a Plugin ABI publication. `scripts/plugin-abi-publish.sh` writes the
# immutable per-build name and verifies what it wrote, and this script is the only thing allowed to
# move `v1.0.0-<host>` afterwards. It takes the release record rather than a command line, because
# the record is written after verification and before this point: a promotion driven by arguments
# assembled in parallel would be able to advertise a digest nothing checked.
#
# Names come from the naming function, not from the record. The record's alias entries are compared
# against what `render tags` produces for the same packaging revision, so a release record that
# drifted away from the code that wrote it stops the promotion instead of quietly moving a name the
# contract no longer describes.

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

release_record=${1:?release record is required}
[[ -f ${release_record} ]] || die "no release record at ${release_record}"

# One record file per host, under a directory this run empties before writing. `promote-alias.sh`
# writes its undo record at the `PROMOTE_ALIAS_RECORD` path it is given, so a single shared path would
# let the second host's promotion truncate the record of the first: the move that most needs an undo
# would be the one no longer described. A directory emptied at the start also means a record left by an
# earlier run can never be mistaken for this run's licence to undo. The path is checked here, before
# anything is read or written, because this script deletes what it is given.
move_record_dir=${PROMOTE_ALIAS_RECORD_DIR:-"${repository_root}/tmp/alias-moves"}
[[ ${move_record_dir} == /* && ${move_record_dir} == */alias-moves ]] ||
  die "PROMOTE_ALIAS_RECORD_DIR must be an absolute directory named alias-moves: ${move_record_dir}"

require_command jq docker
"${script_dir}/plugin-abi.sh" validate --release

packaging_revision=$(jq -er '.packaging_revision' "${release_record}")
[[ ${packaging_revision} =~ ^[0-9a-f]{40}$ ]] ||
  die "the release record names no full packaging commit: ${packaging_revision}"
# The names promoted here must be the names the build won, so they are re-rendered from the record's
# own commit rather than read out of the record. `none` would render no canonical name at all.
# The revision is an environment prefix on the render itself. Attaching it to the assignment instead
# would set a shell variable that the command substitution never sees, and the render would die on a
# missing name revision while looking like it had succeeded.
tags=$(PLUGIN_ABI_NAME_REVISION=${packaging_revision} "${script_dir}/plugin-abi.sh" render tags --release)

promoted_hosts=$(jq -er '.runtime | keys_unsorted | sort | join(" ")' "${release_record}" 2>/dev/null || true)
[[ -n ${promoted_hosts} ]] || { log 'no runtime image was published by this release, so no alias is promoted'; exit 0; }

rm -rf -- "${move_record_dir}"
mkdir -p "${move_record_dir}"

# A host whose canonical name was left alone because an accounted predecessor holds it was not written
# by this build. Its digest is not in the record, and pointing the public name at bytes this release
# did not verify would be the exact failure this ordering exists to prevent.
skipped=$(jq -r '.superseded_hosts[]?' "${release_record}" | paste -sd' ' -)
for host_id in ${promoted_hosts}; do
  if [[ " ${skipped} " == *" ${host_id} "* ]]; then
    die "${host_id} is recorded as superseded and was not written by this build; its alias cannot be promoted from this record"
  fi
done

for host_id in ${promoted_hosts}; do
  published=$(jq -er --arg host "${host_id}" '.runtime[$host]' "${release_record}")
  alias_from_record=$(jq -er --arg host "${host_id}" '.runtime_aliases[$host]' "${release_record}")
  canonical_tag=$(jq -er --arg host "${host_id}" '.runtime[$host].canonical | split(":")[1]' <<<"${tags}") ||
    die "${host_id}: the naming function renders no canonical name for this host"
  alias_tag=$(jq -er --arg host "${host_id}" '.runtime[$host].alias | split(":")[1]' <<<"${tags}")

  # The registry the images live in is a fact about the release, not about the naming function, so the
  # comparison is made on the tag part alone. A record that left the same tag but named a different
  # repository would be promoting a name in a repository this build never wrote to, and
  # `promote-alias.sh` refuses an alias outside the canonical tag's repository for exactly that reason.
  repository=${published%@*}
  verified_digest=${published#*@}
  [[ ${verified_digest} == sha256:* ]] ||
    die "${host_id}: the release record does not address the published image by digest: ${published}"
  [[ ${alias_from_record} == "${repository}:${alias_tag}" ]] ||
    die "${host_id}: the release record would move ${alias_from_record} while the naming function says ${repository}:${alias_tag}"
  [[ ${canonical_tag} != "${alias_tag}" ]] || die "${host_id}: canonical and alias are the same name"

  # `<repo>@<digest>` from the record, `<repo>:<tag>` from the render: promote-alias.sh takes the tag
  # so it can re-resolve the name itself, and takes the digest so the move is licensed by the specific
  # content that was verified rather than by whatever the name happens to hold a moment later.
  PROMOTE_ALIAS_RECORD="${move_record_dir}/alias-move-${host_id}.json" \
    "${script_dir}/promote-alias.sh" "${repository}:${canonical_tag}" "${verified_digest}" "${repository}:${alias_tag}"
  log "promoted ${repository}:${alias_tag} to ${verified_digest}"
done
