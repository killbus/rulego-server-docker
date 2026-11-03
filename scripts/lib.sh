#!/usr/bin/env bash

set -Eeuo pipefail

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

require_command() {
  local command_name
  for command_name in "$@"; do
    command -v "${command_name}" >/dev/null 2>&1 || die "required command not found: ${command_name}"
  done
}

require_positive_integer() {
  local name=${1:?name is required}
  local value=${2-}
  [[ ${value} =~ ^[1-9][0-9]*$ ]] || die "${name} must be a positive integer"
}

validate_version() {
  local version=${1:?version is required}
  [[ ${version} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must match vMAJOR.MINOR.PATCH: ${version}"
}

next_retry_delay() {
  local delay=${1:?delay is required}
  local maximum=${2:?maximum is required}
  if ((delay >= maximum || delay * 2 > maximum)); then
    printf '%s\n' "${maximum}"
  else
    printf '%s\n' "$((delay * 2))"
  fi
}

is_transient_curl_exit() {
  case ${1:?curl exit status is required} in
    # DNS/connect/TLS failures, partial or empty responses, timeouts, send or
    # receive failures, and HTTP/2 stream errors are safe to retry for GETs.
    5 | 6 | 7 | 16 | 18 | 28 | 35 | 52 | 55 | 56 | 92)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_transient_http_response() {
  local status=${1:?HTTP status is required}
  local headers=${2:?header file is required}
  local body=${3:?body file is required}

  case ${status} in
    408 | 425 | 429 | 5??)
      return 0
      ;;
    403)
      # GitHub uses 403 as well as 429 when an API rate limit is exhausted.
      grep -Eiq '^(retry-after:[[:space:]]*[0-9]+|x-ratelimit-remaining:[[:space:]]*0)[[:space:]]*$' "${headers}" \
        || grep -Eiq 'rate limit|rate-limit' "${body}"
      ;;
    *)
      return 1
      ;;
  esac
}

http_get_with_retry() {
  local output=${1:?output path is required}
  local request_timeout=${2:?request timeout is required}
  local url=${3:?URL is required}
  shift 3

  local attempts=${HTTP_RETRY_ATTEMPTS:-8}
  local delay=${HTTP_RETRY_INITIAL_DELAY:-2}
  local max_delay=${HTTP_RETRY_MAX_DELAY:-30}
  require_positive_integer HTTP_RETRY_ATTEMPTS "${attempts}"
  require_positive_integer HTTP_RETRY_INITIAL_DELAY "${delay}"
  require_positive_integer HTTP_RETRY_MAX_DELAY "${max_delay}"

  local output_dir temporary_body temporary_headers
  output_dir=$(dirname -- "${output}")
  mkdir -p -- "${output_dir}"
  temporary_body=$(mktemp "${output_dir}/.http-body.XXXXXX")
  temporary_headers=$(mktemp "${output_dir}/.http-headers.XXXXXX")

  local attempt curl_status http_status retry_reason
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    : >"${temporary_headers}"
    http_status=
    if http_status=$(curl \
      --silent \
      --show-error \
      --location \
      --connect-timeout 15 \
      --max-time "${request_timeout}" \
      --dump-header "${temporary_headers}" \
      --output "${temporary_body}" \
      --write-out '%{http_code}' \
      "$@" \
      "${url}"); then
      curl_status=0
    else
      curl_status=$?
    fi

    if ((curl_status == 0)) && [[ ${http_status} =~ ^2[0-9][0-9]$ ]]; then
      mv -- "${temporary_body}" "${output}"
      rm -f -- "${temporary_headers}"
      return 0
    fi

    retry_reason=
    if ((curl_status != 0)) && is_transient_curl_exit "${curl_status}"; then
      retry_reason="curl exit ${curl_status}"
    elif ((curl_status == 0)) && is_transient_http_response \
      "${http_status}" "${temporary_headers}" "${temporary_body}"; then
      retry_reason="HTTP ${http_status}"
    fi

    if [[ -z ${retry_reason} ]] || ((attempt == attempts)); then
      rm -f -- "${temporary_body}" "${temporary_headers}"
      if ((curl_status != 0)); then
        die "request failed for ${url} (curl exit ${curl_status})"
      fi
      die "request failed for ${url} (HTTP ${http_status:-unknown})"
    fi

    log "temporary ${retry_reason} for ${url} (attempt ${attempt}/${attempts}); retrying in ${delay}s"
    sleep "${delay}"
    delay=$(next_retry_delay "${delay}" "${max_delay}")
  done
}

github_api_get() {
  local output=${1:?output path is required}
  local url=${2:?URL is required}
  local curl_args=(
    --header 'Accept: application/vnd.github+json'
    --header 'X-GitHub-Api-Version: 2022-11-28'
  )

  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    curl_args+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  http_get_with_retry "${output}" 300 "${url}" "${curl_args[@]}"
}

download_get() {
  local output=${1:?output path is required}
  local url=${2:?URL is required}
  http_get_with_retry "${output}" 900 "${url}"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

# Pin every context entry to the locked reproducible epoch and to canonical
# modes. buildkit copies mtime from the build context for file entries and for
# the destination directory of a directory-form COPY, and it stamps synthetic
# parent directories with the build clock, so an unpinned context makes the
# child image digest depend on wall time. Modes come from the runner's umask
# unless they are set here, which would make the digest depend on who built
# the image. Stamping happens once, at the single boundary where build inputs
# enter the context.
stamp_reproducible_tree() {
  local root=${1:?context tree is required}
  local epoch=${2:?reproducible epoch is required}
  [[ ${epoch} =~ ^[0-9]+$ ]] || die "reproducible epoch must be an integer: ${epoch}"
  [[ -d ${root} ]] || die "context tree is missing: ${root}"
  find "${root}" -depth -exec touch -h -a -m -d "@${epoch}" {} +
  find "${root}" -type f -perm /111 -exec chmod 0755 {} +
  find "${root}" -type f ! -perm /111 -exec chmod 0644 {} +
  find "${root}" -type d -exec chmod 0755 {} +
}

# Fail closed if any context entry carries a time other than the locked epoch
# or a mode other than the canonical ones. Without this probe, a skipped or
# reordered stamp silently returns the build-time nondeterminism that makes
# every gate rejection ambiguous.
assert_reproducible_tree() {
  local root=${1:?context tree is required}
  local epoch=${2:?reproducible epoch is required}
  [[ ${epoch} =~ ^[0-9]+$ ]] || die "reproducible epoch must be an integer: ${epoch}"
  [[ -d ${root} ]] || die "context tree is missing: ${root}"

  # %T@ prints seconds with a fractional part, so the comparison is numeric and
  # any sub-second drift fails as well. Symlink modes are not normalizable and
  # are therefore not asserted.
  local reason
  reason=$(
    LC_ALL=C find "${root}" -printf '%T@ %m %y %p\n' |
      awk -v epoch="${epoch}" '
        function bad(why) { sub(/^[^ ]* [^ ]* [^ ]* /, ""); printf "%s: %s\n", why, $0; exit }
        ($1 + 0) != epoch { bad("mtime is not the locked epoch " epoch) }
        $3 == "d" && $2 != "755" { bad("directory mode is not 0755") }
        $3 == "f" && $2 != "644" && $2 != "755" { bad("file mode is neither 0644 nor 0755") }
      '
  ) || die "build context tree cannot be inspected: ${root}"
  [[ -z ${reason} ]] || die "unreproducible build context entry; ${reason}"
}

assert_elf_glibc_max() {
  local elf=${1:?ELF path is required}
  local maximum_allowed=${2:?maximum GLIBC version is required}
  [[ ${maximum_allowed} =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]] \
    || die "invalid maximum GLIBC version: ${maximum_allowed}"
  require_command readelf sort

  local imported maximum_found
  if ! imported=$(readelf --version-info "${elf}" \
    | grep -oE 'GLIBC_[0-9]+([.][0-9]+)+' \
    | sed 's/^GLIBC_//' \
    | LC_ALL=C sort -Vu); then
    die "could not inspect versioned GLIBC imports: ${elf}"
  fi
  [[ -n ${imported} ]] || die "ELF imports no versioned GLIBC symbols: ${elf}"
  maximum_found=$(tail -n 1 <<<"${imported}")
  [[ $(printf '%s\n%s\n' "${maximum_found}" "${maximum_allowed}" | sort -V | tail -n 1) == "${maximum_allowed}" ]] \
    || die "ELF requires GLIBC_${maximum_found}, above locked GLIBC_${maximum_allowed}: ${elf}"
}

extract_safe_tar() {
  local archive=${1:?tar archive is required}
  local destination=${2:?extraction destination is required}
  require_command python3
  mkdir -p -- "${destination}"
  python3 - "${archive}" "${destination}" <<'PY'
import os
from pathlib import Path, PurePosixPath
import sys
import tarfile

archive = sys.argv[1]
destination = Path(sys.argv[2]).resolve()

with tarfile.open(archive, "r:*") as source:
    members = source.getmembers()
    seen = set()
    for member in members:
        name = member.name
        path = PurePosixPath(name)
        if (
            not name
            or "\\" in name
            or path.is_absolute()
            or any(part == ".." for part in path.parts)
            or not (member.isfile() or member.isdir())
        ):
            raise SystemExit(f"unsafe tar member: {name}")
        target = (destination / path).resolve()
        if os.path.commonpath((destination, target)) != str(destination):
            raise SystemExit(f"tar member escapes destination: {name}")
        normalized = str(target.relative_to(destination))
        if normalized in seen:
            raise SystemExit(f"duplicate tar member: {name}")
        seen.add(normalized)
    source.extractall(destination, members=members, filter="data")
PY
}

image_manifest_digest() {
  local image_reference=${1:?image reference is required}
  local wait_for_presence=${2:-false}
  [[ ${wait_for_presence} == true || ${wait_for_presence} == false ]] \
    || die 'wait-for-presence must be true or false'
  local attempts=${REGISTRY_RETRY_ATTEMPTS:-8}
  local delay=${REGISTRY_RETRY_INITIAL_DELAY:-3}
  local max_delay=${REGISTRY_RETRY_MAX_DELAY:-30}
  require_positive_integer REGISTRY_RETRY_ATTEMPTS "${attempts}"
  require_positive_integer REGISTRY_RETRY_INITIAL_DELAY "${delay}"
  require_positive_integer REGISTRY_RETRY_MAX_DELAY "${max_delay}"

  local temporary_dir manifest_file error_file
  temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/rulego-manifest.XXXXXX")
  manifest_file=${temporary_dir}/manifest.json
  error_file=${temporary_dir}/error.log

  local attempt status digest retry_reason
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    retry_reason=
    : >"${error_file}"
    if docker buildx imagetools inspect "${image_reference}" \
      --format '{{json .Manifest}}' >"${manifest_file}" 2>"${error_file}"; then
      if ! jq -e . "${manifest_file}" >/dev/null 2>&1; then
        retry_reason='invalid manifest JSON'
      elif ! jq -e '
        (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
        and ([.manifests[]?
          | select(.platform.os == "linux" and .platform.architecture == "amd64")]
          | length == 1)
        and ([.manifests[]?
          | select(.platform.os == "linux" and .platform.architecture == "arm64")]
          | length == 1)
      ' "${manifest_file}" >/dev/null; then
        if [[ ${wait_for_presence} == true ]]; then
          retry_reason='incomplete image index'
        else
          log "image index is absent or incomplete (requires exactly one linux/amd64 and one linux/arm64): ${image_reference}"
          rm -rf -- "${temporary_dir}"
          return 1
        fi
      else
        digest=$(jq -er '.digest' "${manifest_file}")
        rm -rf -- "${temporary_dir}"
        printf '%s\n' "${digest}"
        return 0
      fi
    else
      status=$?
      if grep -Eqi 'manifest unknown|name unknown|(^|[[:space:]:])not found([[:space:]]|$)' "${error_file}"; then
        if [[ ${wait_for_presence} == true ]]; then
          retry_reason='image manifest not yet visible'
        else
          rm -rf -- "${temporary_dir}"
          return 1
        fi
      else
        retry_reason="registry command exit ${status}"
      fi
    fi

    if ((attempt == attempts)); then
      if [[ -s ${error_file} ]]; then
        cat "${error_file}" >&2
      else
        log "${retry_reason} after ${attempts} attempts: ${image_reference}"
      fi
      rm -rf -- "${temporary_dir}"
      return 2
    fi

    log "temporary ${retry_reason} for ${image_reference} (attempt ${attempt}/${attempts}); retrying in ${delay}s"
    sleep "${delay}"
    delay=$(next_retry_delay "${delay}" "${max_delay}")
  done
}

image_reference_digest() {
  local image_reference=${1:?image reference is required}
  local attempts=${REGISTRY_RETRY_ATTEMPTS:-8}
  local delay=${REGISTRY_RETRY_INITIAL_DELAY:-3}
  local max_delay=${REGISTRY_RETRY_MAX_DELAY:-30}
  require_positive_integer REGISTRY_RETRY_ATTEMPTS "${attempts}"
  require_positive_integer REGISTRY_RETRY_INITIAL_DELAY "${delay}"
  require_positive_integer REGISTRY_RETRY_MAX_DELAY "${max_delay}"

  local temporary_dir manifest_file error_file attempt status digest retry_reason
  temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/rulego-reference.XXXXXX")
  manifest_file=${temporary_dir}/manifest.json
  error_file=${temporary_dir}/error.log
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    retry_reason=
    : >"${error_file}"
    if docker buildx imagetools inspect "${image_reference}" \
      --format '{{json .Manifest}}' >"${manifest_file}" 2>"${error_file}"; then
      if digest=$(jq -er '.digest | select(test("^sha256:[0-9a-f]{64}$"))' "${manifest_file}"); then
        rm -rf -- "${temporary_dir}"
        printf '%s\n' "${digest}"
        return 0
      fi
      retry_reason='invalid manifest JSON or digest'
    else
      status=$?
      if grep -Eqi 'manifest unknown|name unknown|(^|[[:space:]:])not found([[:space:]]|$)' "${error_file}"; then
        rm -rf -- "${temporary_dir}"
        return 1
      fi
      retry_reason="registry command exit ${status}"
    fi
    if ((attempt == attempts)); then
      [[ ! -s ${error_file} ]] || cat "${error_file}" >&2
      log "${retry_reason} after ${attempts} attempts: ${image_reference}"
      rm -rf -- "${temporary_dir}"
      return 2
    fi
    log "temporary ${retry_reason} for ${image_reference} (attempt ${attempt}/${attempts}); retrying in ${delay}s"
    sleep "${delay}"
    delay=$(next_retry_delay "${delay}" "${max_delay}")
  done
}

verify_exact_image_children() {
  local reference=${1:?image reference is required}
  local amd64_digest=${2:?amd64 digest is required}
  local arm64_digest=${3:?arm64 digest is required}
  local output=${4:?manifest output path is required}

  docker buildx imagetools inspect "${reference}" --format '{{json .Manifest}}' >"${output}"
  # `// []` keeps a manifest without an image list answering "not these images" instead of failing
  # inside jq: the caller that has to distinguish a refusal from an unreadable registry is the tag
  # probe, and it should not have to do that through a jq error message in the release log.
  jq -e --arg amd64 "${amd64_digest}" --arg arm64 "${arm64_digest}" '
    ([(.manifests // [])[] | select(.platform.os == "linux") |
      {architecture:.platform.architecture,digest:.digest}] | sort_by(.architecture)) ==
    [{architecture:"amd64",digest:$amd64},{architecture:"arm64",digest:$arm64}]
  ' "${output}" >/dev/null
}

# True when the images an existing index resolves to are exactly the two children this build
# produced. Index annotations and attestation members are excluded on purpose: they record the
# invocation that first wrote them, while the two linux children are the artifacts consumers run.
# This is the comparison `tests/plugin-abi-drivers.sh` says the reproducibility recheck must use,
# applied to publication so an unchanged contract can be released again without a write.
canonical_index_holds_children() {
  local target=${1:?canonical target is required}
  local amd64_child=${2:?amd64 child digest is required}
  local arm64_child=${3:?arm64 child digest is required}

  [[ ${amd64_child} =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "amd64 child digest is required for ${target}"
  [[ ${arm64_child} =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "arm64 child digest is required for ${target}"
  verify_exact_image_children "${target}" "${amd64_child}" "${arm64_child}" \
    "${TMPDIR:-/tmp}/canonical-index-children.$$.json"
}

publish_immutable_image_tag() {
  local target=${1:?target image tag is required}
  local source=${2:?source image digest is required}
  local amd64_child=${3:?amd64 child digest is required}
  local arm64_child=${4:?arm64 child digest is required}
  local expected=${source##*@}
  local existing status

  [[ ${source} =~ @sha256:[0-9a-f]{64}$ ]] || die "source image must be addressed by digest: ${source}"
  if existing=$(image_reference_digest "${target}"); then
    # Writing nothing is correct whenever the name already resolves to this build's images, even
    # though the index digest above it differs: the two attestation members inside that index
    # describe whichever invocation wrote them first, and the name belongs to that first writer.
    if [[ ${existing} == "${expected}" ]] ||
      canonical_index_holds_children "${target}" "${amd64_child}" "${arm64_child}"; then
      printf '%s@%s\n' "${target%:*}" "${existing}"
      return
    fi
    die "immutable tag already resolves to different images than this build produced: ${target}"
  else
    status=$?
    ((status == 1)) || return "${status}"
  fi

  retry_command 4 2 docker buildx imagetools create --tag "${target}" "${source}"
  existing=$(image_reference_digest "${target}") || die "canonical tag was not published: ${target}"
  [[ ${existing} == "${expected}" ]] || die "canonical index digest changed during publication: ${target}"
  printf '%s@%s\n' "${target%:*}" "${existing}"
}

# Reads the state of one canonical tag without writing: <status>\t<held-by-abi-id>. `absent`
# covers a name nothing holds, `occupied` a name that resolves to an index, and `unreachable`
# anything the registry could not answer for, which is never reported as free. The holding
# identity comes from the `io.rulego.abi.id` index annotation that publication already writes,
# so no separate provenance channel is needed and no digest is compared, because the content of an
# unpublished canonical tag does not exist yet to compare against.
canonical_tag_probe() {
  local target=${1:?canonical tag is required}
  local status annotations held_by

  # The digest itself is not compared: an unpublished canonical tag has no content of this
  # lock's to compare against, so only its occupancy is of interest here.
  status=0
  image_reference_digest "${target}" >/dev/null || status=$?
  case ${status} in
    0) ;;
    1)
      printf 'absent\t\n'
      return 0
      ;;
    *)
      printf 'unreachable\t\n'
      return 0
      ;;
  esac

  if ! annotations=$(docker buildx imagetools inspect "${target}" \
    --format '{{json .Manifest}}' | jq -c '.annotations // {}'); then
    printf 'unreachable\t\n'
    return 0
  fi
  if ! held_by=$(jq -er '."io.rulego.abi.id" // "unlabelled"' <<<"${annotations}"); then
    printf 'unreachable\t\n'
    return 0
  fi
  printf 'occupied\t%s\n' "${held_by}"
}

# Derives the canonical tag plan from rendered tags and a registry owner, as
# <identity>\t<target> lines, in the order publication writes them. Publication builds the same
# targets inline from the same rendered tags and the same owner, so the inputs are shared even
# though this function has one caller; what the probe must not do is report on a different set of
# names than the one publication writes, and `tests/canonical-tag-allocatability.sh` holds both
# sides to that. The SDK is named by its identity, so it cannot collide with a different ABI; the
# runtime hosts are named by the upstream release plus a host suffix, which is exactly why they
# can collide and why they are probed one at a time.
canonical_tag_plan() {
  local tags=${1:?rendered tags are required}
  local owner=${2:?registry owner is required}

  jq -r --arg owner "${owner}" '
    [ {identity: "plugin-sdk", target: ("ghcr.io/" + $owner + "/" + .sdk)} ] +
    # The plan carries canonical names only. An alias is a moving name and must never appear here,
    # because everything downstream treats a plan line as a first-writer promise. A null canonical is
    # the pre-build state: no build has decided that name yet, so there is nothing to promise and no
    # line to write. Publication counts the lines it gets against the lock, so a null there is refused
    # rather than read as a smaller batch.
    [ .runtime | to_entries[] | select(.value.canonical != null) |
        {identity: ("runtime-" + .key), target: ("ghcr.io/" + $owner + "/" + .value.canonical)} ] |
    .[] | [.identity, .target] | @tsv' <<<"${tags}"
}

# A plan is a promise about every artifact this release owns, so its size is checked against the lock
# rather than against the render that produced it. A canonical runtime name that came out null -- the
# pre-build state, which only the probe may ask for -- would otherwise look like a smaller batch, and
# the gate would approve a plan that no longer contains the hosts it exists to protect.
require_canonical_plan_lines() {
  local plan_file=${1:?canonical plan file is required}
  local host_count=${2:?host count is required}
  local lines
  lines=$(wc -l <"${plan_file}" | tr -d ' ')
  [[ ${lines} == $((1 + host_count)) ]] ||
    die "canonical plan has ${lines} lines for ${host_count} hosts plus the SDK; a canonical name is missing from the plan"
}

# Classifies one canonical tag probe into a verdict, given the identity this lock claims and the
# identity of the contract it replaced. It is a function rather than inline conditions so the
# classification itself is testable offline without a registry.
#
# `superseded` is not a failure. A runtime canonical tag is named after the upstream release, so a
# tag an earlier contract already claimed stays claimed forever; treating that as red would make
# main permanently red and invite the gate to be weakened until it meant nothing, which is how a
# check dies. It is reported instead, because it is the real blocker for a release and the
# operator has to see which name causes it. A name held by an identity the lock does not account
# for is unexplained, and an unprobed name is never treated as free.
#
# Publication is stricter than this by design and stays that way: it compares digests of built
# content in one all-or-nothing gate, while a name cannot be compared to content that has not been
# built yet. This function classifies names; it does not license a write.
canonical_predecessor_holds() {
  # `predecessors` is a set, one identity per line. A name can be legitimately spent by more than
  # one earlier contract, and a single slot cannot hold both the generation this release replaced
  # and a generation abandoned under a different identity function. Measured on the live registry
  # with one slot: `v1.0.0-plugin` and `v1.0.0-ai-plugin` come out superseded and collision in
  # exactly complementary pairs, so whichever single identity is recorded, the other name kills
  # the whole batch. A set is what makes "accounted for" mean something.
  local held_by=${1:-}
  local predecessors=${2:-}
  local predecessor

  [[ -n ${held_by} ]] || return 1
  while IFS= read -r predecessor; do
    [[ -n ${predecessor} && ${held_by} == "${predecessor}" ]] && return 0
  done <<<"${predecessors}"
  return 1
}

# Reads the identities this release accounts for, one per line: the immediate predecessor recorded
# in the lock, plus every earlier cast recorded in `plugin-abi-history.json`.
#
# The set deliberately lives OUTSIDE the lock. The lock is canonicalized into the manifest that is
# copied into both images, so an entry added here would change every published digest without
# changing one compiled byte -- which is the exact drift this repository records as its known gap in
# tests/plugin-abi-identity-vectors.sh. Predecessor accounting is a publication-history fact, and
# publication history is not an organ of the artifact.
canonical_predecessor_abi_ids() {
  local lock_file=${1:?Plugin ABI lock is required}
  local history_file=${2:-${PLUGIN_ABI_HISTORY:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/plugin-abi-history.json}}

  [[ -f ${history_file} ]] || die "Plugin ABI publication history not found: ${history_file}"
  jq -er '
    ([.compatibility.previous_sdk.abi_id])[]' "${lock_file}"
  # Not `jq -e`: an empty history is a legal state, and -e reports "no output" as a failure.
  jq -r '.predecessors[] | .abi_id' "${history_file}"
}

# Validates the publication history against the lock it will be read with. An entry with no reason
# is rejected because a predecessor list nobody can justify is indistinguishable from a list
# written to make a gate pass, and an entry naming this lock's own identity would turn
# self-supersession into a skip.
validate_publish_history() {
  local lock_file=${1:?Plugin ABI lock is required}
  local history_file=${2:-${PLUGIN_ABI_HISTORY:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/plugin-abi-history.json}}
  local abi_id

  [[ -f ${history_file} ]] || die "Plugin ABI publication history not found: ${history_file}"
  abi_id=$(jq -er '.abi_id' "${lock_file}") ||
    die "cannot read abi_id from ${lock_file}"
  jq -e --arg self "${abi_id}" '
    def nonempty: type == "string" and length > 0;
    (. == {schema_version: 1, predecessors: .predecessors}) and
    (.predecessors | type == "array") and
    (.predecessors | all(. == {abi_id: .abi_id, reason: .reason})) and
    ([.predecessors[].abi_id | nonempty and test("^abi-[0-9a-f]{64}$")] | all) and
    ([.predecessors[].abi_id] | unique | length) == (.predecessors | length) and
    ([.predecessors[].abi_id] | all(. != $self)) and
    ([.predecessors[].reason | nonempty] | all)' "${history_file}" >/dev/null ||
    die "invalid Plugin ABI publication history: ${history_file}"
}

canonical_tag_verdict() {
  local probe_status=${1:?probe status is required}
  local held_by=${2:-}
  local this_abi=${3:?this identity is required}
  local predecessors=${4:?predecessor identities are required}

  case ${probe_status} in
    absent) printf 'allocatable\n' ;;
    occupied)
      if [[ ${held_by} == "${this_abi}" ]]; then
        printf 'republish\n'
      elif canonical_predecessor_holds "${held_by}" "${predecessors}"; then
        printf 'superseded\n'
      else
        printf 'collision\n'
      fi
      ;;
    unreachable) printf 'unreachable\n' ;;
    *) die "unknown canonical tag probe status: ${probe_status}" ;;
  esac
}

# Decides what publication may do with one canonical tag, from facts supplied by the caller.
# It performs no I/O so the rule that unblocks a release stays testable offline: a registry
# answer is the only input that needs one.
#
# `content_matches` answers one question and nothing else: do the images this build produced equal
# the images that the published index already resolves to? It is deliberately not "is the index
# digest equal", because a multi-architecture index carries one SLSA provenance and one SBOM
# attestation member per platform, and those members describe the invocation that built them, so
# the index digest moves on every build by design. `scripts/plugin-abi-build.sh` compares child
# digests for the same reason, and `verify_exact_image_children` is the check publication reuses.
# Judging equality at the index would make an unchanged contract impossible to republish: every
# rerun would differ, every difference would read as a conflict, and the only advice the gate could
# offer would be to wait for a name nobody has claimed yet.
#
# `noop` is the case `publish_immutable_image_tag` tolerates: the name already resolves to this
# build's images, so a rerun needs no write. It is checked before any identity comparison because
# content equality outranks provenance.
#
# `superseded` means an earlier contract owns the name. Runtime canonical tags are named after the
# upstream release alone, so once that contract claimed the name no later lock can; the earlier
# digest still satisfies the name's promise, and consumers pin it unchanged. This is the one
# verdict that must not block a release, because blocking on it makes main permanently red -- the
# condition under which a gate gets weakened until it means nothing.
#
# `identity-conflict` is narrower and genuinely fatal: the holder carries *this* lock's ABI identity
# yet a different digest, which is two packaging revisions of one contract claiming the same
# immutable name. Advancing `release_version` is the honest exit while a packaging revision is
# baked into the artifact; see the note above `canonical_predecessor_holds` for why recording an
# extra predecessor is what makes a renamed identity function survivable instead of fatal.
#
# `collision` is a holder this lock accounts for in neither way, and `unreachable` is a registry
# that could not answer; neither is ever read as free.
canonical_tag_publish_decision() {
  local probe_status=${1:?probe status is required}
  local held_by=${2:-}
  local content_matches=${3:?content comparison result is required}
  local this_abi=${4:?this identity is required}
  local predecessors=${5:-}

  [[ ${content_matches} == yes || ${content_matches} == no ]] ||
    die "content comparison must be answered yes or no, found: ${content_matches}"

  case ${probe_status} in
    unreachable)
      printf 'unreachable\n'
      return
      ;;
    absent)
      printf 'publish\n'
      return
      ;;
    occupied) ;;
    *) die "unknown canonical tag probe status: ${probe_status}" ;;
  esac

  if [[ ${content_matches} == yes ]]; then
    printf 'noop\n'
  elif canonical_predecessor_holds "${held_by}" "${predecessors}"; then
    printf 'superseded\n'
  elif [[ ${held_by} == "${this_abi}" ]]; then
    printf 'identity-conflict\n'
  else
    printf 'collision\n'
  fi
}

# Probes every canonical target before any tag is written.
#
# The decision is `canonical_tag_publish_decision` above; this function supplies it from the
# registry and separates two things the old gate conflated. A name whose digest is not this
# build's was always a block, so a tag owned by the contract this lock supersedes refused every
# tag in the batch -- including variants whose own names are free -- and the rejection named no
# variant. Supersession is a fact the lock already records, so it is now a skip, not a stop.
#
# Every name is echoed as `<identity>\t<decision>`, one of `publish`, `noop`, or `superseded`, so
# the caller decides per artifact rather than rediscovering the verdict. `noop` means the name
# already holds exactly this build's digest: writing is unnecessary, the ref still belongs in the
# release record. `superseded` means the name is satisfied by another contract's digest and this
# release must not reach for it.
#
# A real conflict still refuses the whole batch. That is the point of the gate: a release that
# cannot claim all the names it means to claim should claim none of them.
# Each plan line is <canonical-target>\t<digest-addressed-source>\t<identity>\t<amd64-child>\t<arm64-child>.
# The two child digests come from the native build evidence, which is the same source
# `verify_index_children` checks the staging indexes against, so the gate and the writer compare the
# release plan with the bytes that were actually produced rather than with an index that cannot be
# reproduced by design.
require_immutable_tags_publishable() {
  local plan=${1:?canonical tag plan is required}
  [[ -f ${plan} ]] || die "canonical tag plan not found: ${plan}"

  # The identities compared below come from the same lock the tags were rendered from. Resolving
  # it any other way would let the verdict be evidence about a contract nobody is publishing.
  local repository_root lock_file abi_id predecessors
  repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  lock_file=${PLUGIN_ABI_LOCK:-${repository_root}/plugin-abi.lock}
  [[ -f ${lock_file} ]] || die "Plugin ABI lock not found: ${lock_file}"
  abi_id=$(jq -er '.abi_id' "${lock_file}") || die "cannot read abi_id from ${lock_file}"
  validate_publish_history "${lock_file}"
  predecessors=$(canonical_predecessor_abi_ids "${lock_file}") ||
    die "cannot read the predecessor identities from ${lock_file}"

  local target source identity amd64_child arm64_child expected existing status
  local held_by probe_status content_matches decision
  local identity_conflict_targets=() collision_targets=() unreachable_targets=()
  while IFS=$'\t' read -r target source identity amd64_child arm64_child; do
    [[ -n ${target} && -n ${source} && -n ${identity} && -n ${amd64_child} && -n ${arm64_child} ]] ||
      die "canonical tag plan line must carry target, source, identity and both child digests: ${plan}"
    expected=${source##*@}
    [[ ${source} =~ @sha256:[0-9a-f]{64}$ ]] ||
      die "source image must be addressed by digest: ${source}"
    [[ ${amd64_child} =~ ^sha256:[0-9a-f]{64}$ && ${arm64_child} =~ ^sha256:[0-9a-f]{64}$ ]] ||
      die "canonical tag plan child digests are invalid for ${identity}"

    content_matches=no
    if existing=$(image_reference_digest "${target}"); then
      if [[ ${existing} == "${expected}" ]] ||
        canonical_index_holds_children "${target}" "${amd64_child}" "${arm64_child}"; then
        probe_status=occupied held_by=${abi_id} content_matches=yes
      else
        # The digest differs, so the question is whose it is. That answer lives in the index
        # annotation publication writes, not in the digest.
        # A child comparison that cannot be made is not a difference: the probe below is what
        # distinguishes a registry that refused to answer from a tag holding other bytes.
        IFS=$'\t' read -r probe_status held_by < <(canonical_tag_probe "${target}") ||
          die "canonical tag probe returned no verdict for ${target}"
      fi
    else
      status=$?
      ((status == 1)) || die "canonical tag cannot be inspected: ${target}"
      probe_status=absent held_by=''
    fi

    decision=$(canonical_tag_publish_decision "${probe_status}" "${held_by}" \
      "${content_matches}" "${abi_id}" "${predecessors}")
    case ${decision} in
      publish|noop|superseded)
        printf '%s\t%s\n' "${identity}" "${decision}"
        ;;
      identity-conflict) identity_conflict_targets+=("${identity} at ${target}") ;;
      collision) collision_targets+=("${identity} at ${target} is held by ${held_by:-an unreadable identity}") ;;
      unreachable) unreachable_targets+=("${identity} at ${target}") ;;
      *) die "unexpected canonical tag publish decision for ${target}: ${decision}" ;;
    esac
  done <"${plan}"

  # One message per cause. A single remedy line for three unrelated causes sends the reader to the
  # wrong place: `advance release_version` can open a runtime name that a later contract holds, but
  # it cannot make two different byte sets share one identity-named tag, and it has nothing to do
  # with a registry that did not answer. The old text was measured doing exactly that -- it named
  # the upstream release as the fix for a defect in this repository's own byte recipe.
  (( ${#identity_conflict_targets[@]} + ${#collision_targets[@]} + ${#unreachable_targets[@]} == 0 )) && return
  local reasons=()
  (( ${#identity_conflict_targets[@]} == 0 )) ||
    reasons+=("identity-conflict: $(printf '%s; ' "${identity_conflict_targets[@]}") already hold a build of \
this contract with different bytes. Only two answers are honest: record the change in the identity \
closure so this contract gets its own new name, or leave that name to the bytes it already holds. \
Advancing release_version does not help, because this name is computed from the contract, not from \
the release version.")
  (( ${#collision_targets[@]} == 0 )) ||
    reasons+=("collision: $(printf '%s; ' "${collision_targets[@]}"). If that identity is an earlier \
contract this lock supersedes, add it to plugin-abi-history.json with a reason and the name becomes a \
skip; otherwise a release nobody accounts for is published under this name and must not be displaced.")
  (( ${#unreachable_targets[@]} == 0 )) ||
    reasons+=("unreachable: $(printf '%s; ' "${unreachable_targets[@]}") could not be read from the \
registry. That is not the same as the name being free; re-run once the registry answers.")
  die "no tag written; $(printf '%s ' "${reasons[@]}")"
}

# Turns the gate's `<identity>\t<decision>` lines into the runtime hosts this release must leave
# alone. `runtime-` is the identity prefix publication gives each host, and the verifier and the
# release record both work in bare host ids, so the prefix is stripped here once rather than at
# each consumer.
canonical_superseded_hosts() {
  jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t") | select(.[1] == "superseded") | .[0])
    | map(sub("^runtime-"; ""))' <<<"${1:-}"
}

# True when no decision line marks the SDK as superseded. The SDK canonical tag is named after this
# contract's own identity, so no other contract can hold it legitimately; a release that skipped it
# would publish runtimes whose record cannot name the SDK they were built with.
canonical_sdk_superseded() {
  ! jq -e -Rs '
    split("\n") | map(select(length > 0) | split("\t"))
    | map(select(.[0] == "plugin-sdk" and .[1] == "superseded")) | length > 0
  ' <<<"${1:-}" >/dev/null
}

retry_command() {
  local attempts=${1:?attempt count is required}
  local delay=${2:?initial delay is required}
  shift 2

  require_positive_integer attempts "${attempts}"
  require_positive_integer delay "${delay}"

  local attempt status
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if "$@"; then
      return 0
    else
      status=$?
    fi

    if ((attempt == attempts)); then
      return "${status}"
    fi

    log "command failed (attempt ${attempt}/${attempts}); retrying in ${delay}s"
    sleep "${delay}"
    delay=$(next_retry_delay "${delay}" 30)
  done
}
