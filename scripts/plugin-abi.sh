#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=scripts/lib.sh
source "${script_dir}/lib.sh"

lock=${PLUGIN_ABI_LOCK:-${repository_root}/plugin-abi.lock}

usage() {
  cat >&2 <<'EOF'
usage: scripts/plugin-abi.sh validate <--candidate|--release>
       scripts/plugin-abi.sh render <id|lock-digest|manifest|matrix|ci|editor>
       scripts/plugin-abi.sh render build <amd64|arm64>
       scripts/plugin-abi.sh render sdk-env <amd64|arm64> [host-id]
       scripts/plugin-abi.sh render compatibility-sdk <amd64|arm64>
       scripts/plugin-abi.sh render size-limit <amd64|arm64> [host-id]
       scripts/plugin-abi.sh render metadata <plugin-sdk|plugin-runtime> [amd64|arm64] [host-id]
       scripts/plugin-abi.sh render tags [--candidate|--release]
EOF
  exit 2
}

canonical_abi() {
  # tr -d '\r' makes the canonical bytes platform-stable: jq -c on non-LF
  # platforms appends a CR that would otherwise change the derived abi_id.
  jq -S -c '.abi' "${lock}" | tr -d '\r'
}

calculated_abi_id() {
  printf 'abi-%s\n' "$(canonical_abi | sha256sum | awk '{print $1}')"
}

canonical_manifest() {
  jq -S -c . "${lock}" | tr -d '\r'
}

lock_digest() {
  canonical_manifest | sha256sum | awk '{print "sha256:" $1}'
}

validate_lock() {
  local mode=${1:?validation mode is required}
  [[ ${mode} == --candidate || ${mode} == --release ]] || usage
  require_command jq sha256sum
  [[ -f ${lock} ]] || die "Plugin ABI lock not found: ${lock}"
  jq -e . "${lock}" >/dev/null || die 'Plugin ABI lock is not valid JSON'

  jq -e '
    def exact_keys($keys): ((keys_unsorted | sort) == ($keys | sort));
    def nonempty: type == "string" and length > 0;
    def sha256: type == "string" and test("^[0-9a-f]{64}$");
    def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
    def revision: type == "string" and test("^[0-9a-f]{40}$");
    def pinned_image: type == "string" and test("^[^[:space:]@]+(:[^@[:space:]]+)?@sha256:[0-9a-f]{64}$");
    def no_placeholder: [paths(scalars) as $p | getpath($p) | select(type == "string") | select(test("<[^>]+>|REPLACE|TODO|PENDING"; "i"))] | length == 0;

    . as $root |
    exact_keys(["schema_version", "abi_id", "abi", "compatibility", "release"]) and
    .schema_version == 1 and
    (.abi_id | test("^abi-[0-9a-f]{64}$")) and
    no_placeholder and
    (.abi | exact_keys(["go", "native", "rulego_server", "rulego_core", "module_graph", "build"])) and
    (.abi.go | exact_keys(["version", "compiler", "cgo_enabled", "goos", "targets", "experiments", "environment"])) and
    (.abi.go.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    .abi.go.compiler == "gc" and .abi.go.cgo_enabled == true and .abi.go.goos == "linux" and
    .abi.go.experiments == [] and
    (.abi.go.environment | exact_keys(["GOENV", "GOTOOLCHAIN", "GOFLAGS", "GOEXPERIMENT", "CGO_CFLAGS", "CGO_CPPFLAGS", "CGO_CXXFLAGS", "CGO_LDFLAGS"])) and
    .abi.go.environment.GOENV == "off" and .abi.go.environment.GOTOOLCHAIN == "local" and
    .abi.go.environment.GOFLAGS == "-mod=readonly" and
    ([.abi.go.environment.GOEXPERIMENT, .abi.go.environment.CGO_CFLAGS, .abi.go.environment.CGO_CPPFLAGS, .abi.go.environment.CGO_CXXFLAGS, .abi.go.environment.CGO_LDFLAGS] | all(. == "")) and
    (.abi.go.targets | length == 2) and
    [.abi.go.targets[].goarch] == ["amd64", "arm64"] and
    [.abi.go.targets[].platform] == ["linux/amd64", "linux/arm64"] and
    ([.abi.go.targets[].goarch] | unique | length == 2) and
    ([.abi.go.targets[] | exact_keys(["platform", "goarch", "tuning", "cc", "cxx"])] | all) and
    .abi.go.targets[0].tuning == {"GOAMD64":"v1"} and
    .abi.go.targets[1].tuning == {"GOARM64":"v8.0"} and
    ([.abi.go.targets[] | .cc, .cxx] | all(nonempty)) and
    (.abi.native | exact_keys(["libc", "minimum_version", "sdk_base", "runtime_base", "toolchains"])) and
    .abi.native.libc == "glibc" and
    (.abi.native.minimum_version | test("^[0-9]+\\.[0-9]+$")) and
    (.abi.native.sdk_base | pinned_image) and (.abi.native.runtime_base | pinned_image) and
    (.abi.native.toolchains | length == 2) and
    [.abi.native.toolchains[].goarch] == ["amd64", "arm64"] and
    ([.abi.native.toolchains[] | exact_keys(["goarch", "cc", "cc_version", "linker_command", "linker", "linker_version"])] | all) and
    ([.abi.native.toolchains[] | .cc, .cc_version, .linker_command, .linker, .linker_version] | all(nonempty)) and
    ([range(0; 2) as $i | .abi.native.toolchains[$i].cc == .abi.go.targets[$i].cc] | all) and
    (.abi.rulego_server | exact_keys(["repository", "release_version", "revision", "module", "go_mod_sha256", "go_sum_sha256"])) and
    (.abi.rulego_server.repository | test("^https://github\\.com/[^/]+/[^/]+$")) and
    (.abi.rulego_server.release_version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.abi.rulego_server.revision | revision) and (.abi.rulego_server.module | nonempty) and
    (.abi.rulego_server.go_mod_sha256 | sha256) and (.abi.rulego_server.go_sum_sha256 | sha256) and
    (.abi.rulego_core | exact_keys(["module", "version", "revision"])) and
    (.abi.rulego_core.module | nonempty) and (.abi.rulego_core.version | nonempty) and
    (.abi.rulego_core.revision | revision) and
    ((.abi.rulego_core.version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) or
     (.abi.rulego_core.version | endswith($root.abi.rulego_core.revision[0:12]))) and
    (.abi.module_graph | exact_keys(["list_sha256", "graph_sha256", "replacements"])) and
    (.abi.module_graph.list_sha256 | sha256) and (.abi.module_graph.graph_sha256 | sha256) and
    .abi.module_graph.replacements == [] and
    (.abi.build | exact_keys(["host_mode", "plugin_mode", "hosts", "host_flags", "plugin_flags", "host_ldflags", "plugin_ldflags", "host_workspace", "plugin_workspace", "plugin_symbol"])) and
    .abi.build.host_mode == "exe" and .abi.build.plugin_mode == "plugin" and
    (.abi.build.hosts | length >= 1) and
    ([.abi.build.hosts[] | exact_keys(["id", "tags", "tag_suffix"])] | all) and
    ([.abi.build.hosts[].id] | all(test("^[a-z0-9]+(-[a-z0-9]+)*$"))) and
    ([.abi.build.hosts[].id] | unique | length) == (.abi.build.hosts | length) and
    ([.abi.build.hosts[].tag_suffix] | unique | length) == (.abi.build.hosts | length) and
    ([.abi.build.hosts[] | .tag_suffix == ("-" + .id)] | all) and
    ([.abi.build.hosts[].tags[]] | all(. == "with_ai" or . == "with_all")) and
    .abi.build.hosts[0] == {"id":"plugin","tags":[],"tag_suffix":"-plugin"} and
    .abi.build.host_flags == ["-trimpath"] and
    .abi.build.plugin_flags == ["-trimpath", "-buildvcs=false"] and .abi.build.host_ldflags == [] and
    .abi.build.plugin_ldflags == [] and .abi.build.host_workspace == "off" and
    .abi.build.plugin_workspace == "generated-server-and-plugin" and .abi.build.plugin_symbol == "Plugins" and
    (.compatibility | exact_keys(["previous_sdk"])) and
    (.compatibility.previous_sdk |
      exact_keys(["abi_id", "repository", "index_digest", "children"])) and
    (.compatibility.previous_sdk.abi_id | test("^abi-[0-9a-f]{64}$")) and
    .compatibility.previous_sdk.abi_id != .abi_id and
    (.compatibility.previous_sdk.repository |
      test("^ghcr\\.io/[a-z0-9]+([._-][a-z0-9]+)*/[a-z0-9]+([._-][a-z0-9]+)*$")) and
    (.compatibility.previous_sdk.index_digest | digest) and
    (.compatibility.previous_sdk.children |
      (keys_unsorted | sort) == ([$root.abi.go.targets[].goarch] | sort)) and
    ([.compatibility.previous_sdk.children[] | digest] | all) and
    (.release | exact_keys(["state", "sdk_image", "runtime_image", "manifest_path", "reproducible_epoch", "ci", "editor_payload", "size_limits"])) and
    (.release.reproducible_epoch | type == "number" and . == floor and . >= 0) and
    (.release.state == "measurement" or .release.state == "ready") and
    ([.release.sdk_image, .release.runtime_image] | all(test("^[a-z0-9]+([._-][a-z0-9]+)*$"))) and
    (.release.manifest_path | startswith("/") and endswith(".json")) and
    (.release.ci | exact_keys(["runners"])) and
    (.release.ci.runners | exact_keys(["amd64", "arm64"])) and
    ([.release.ci.runners.amd64, .release.ci.runners.arm64] | all(nonempty)) and
    (.release.editor_payload | exact_keys(["repository", "version", "asset"])) and
    .release.editor_payload.repository == $root.abi.rulego_server.repository and
    .release.editor_payload.version == $root.abi.rulego_server.release_version and
    (.release.editor_payload.asset | exact_keys(["name", "sha256"])) and
    (.release.editor_payload.asset.name | test("^[A-Za-z0-9._-]+\\.tar\\.gz$")) and
    (.release.editor_payload.asset.sha256 | sha256) and
    (.release.size_limits | exact_keys(["amd64", "arm64"])) and
    ([.release.size_limits[] | exact_keys(["sdk", "runtime"])] | all) and
    ([.release.size_limits[].sdk | exact_keys(["compressed", "uncompressed"])] | all) and
    ([.release.size_limits[].runtime |
      (keys_unsorted | sort) == ([$root.abi.build.hosts[].id] | sort)] | all) and
    ([.release.size_limits[].runtime[] | exact_keys(["compressed", "uncompressed"])] | all)
  ' "${lock}" >/dev/null || die 'Plugin ABI lock schema or values are invalid'

  local expected actual state
  expected=$(calculated_abi_id)
  actual=$(jq -er '.abi_id' "${lock}")
  [[ ${actual} == "${expected}" ]] || die "stale abi_id: expected ${expected}, found ${actual}"

  state=$(jq -er '.release.state' "${lock}")
  if [[ ${mode} == --candidate ]]; then
    if [[ ${state} == measurement ]]; then
      jq -e '[.release.size_limits | .. | select(type != "object")] | all(. == null)' "${lock}" >/dev/null \
        || die 'measurement state permits only null size ceilings'
    else
      jq -e '[.release.size_limits | .. | select(type != "object")] | all(type == "number" and (floor == .) and . > 0)' "${lock}" >/dev/null \
        || die 'ready state requires positive integer size ceilings'
    fi
  else
    [[ ${state} == ready ]] || die 'release validation requires release.state=ready'
    jq -e '[.release.size_limits | .. | select(type != "object")] | all(type == "number" and (floor == .) and . > 0)' "${lock}" >/dev/null \
      || die 'release validation requires positive integer size ceilings'
  fi
}

render_matrix() {
  jq -c '{include: [.abi.go.targets[] as $target | {
    goarch: $target.goarch, platform: $target.platform,
    runner: .release.ci.runners[$target.goarch],
    tuning_key: ($target.tuning | keys[0]),
    tuning_value: ($target.tuning | .[keys[0]])
  }]}' "${lock}"
}

render_ci() {
  jq -c --arg lock_digest "$(lock_digest)" '{
    abi_id, lock_digest: $lock_digest, go_version: .abi.go.version,
    libc_minimum: .abi.native.minimum_version,
    sdk_base: .abi.native.sdk_base, runtime_base: .abi.native.runtime_base,
    server_repository: .abi.rulego_server.repository,
    server_release: .abi.rulego_server.release_version,
    server_revision: .abi.rulego_server.revision,
    manifest_path: .release.manifest_path, release_state: .release.state,
    reproducible_epoch: .release.reproducible_epoch,
    sdk_image: .release.sdk_image, runtime_image: .release.runtime_image,
    hosts: .abi.build.hosts,
    matrix: {include: [.abi.go.targets[] as $target | {
      goarch: $target.goarch, platform: $target.platform,
      runner: .release.ci.runners[$target.goarch],
      tuning_key: ($target.tuning | keys[0]),
      tuning_value: ($target.tuning | .[keys[0]])
    }]}
  }' "${lock}"
}

render_editor() {
  jq -c '.release.editor_payload' "${lock}"
}

render_build() {
  local arch=${1:?build architecture is required}
  jq -ec --arg arch "${arch}" --arg lock_digest "$(lock_digest)" '
    (.abi.go.targets[] | select(.goarch == $arch)) as $target |
    (.abi.native.toolchains[] | select(.goarch == $arch)) as $toolchain |
    {
      abi_id, lock_digest: $lock_digest,
      manifest_path: .release.manifest_path,
      reproducible_epoch: .release.reproducible_epoch,
      go: (.abi.go | del(.targets)), target: $target,
      native: (.abi.native | del(.toolchains)), toolchain: $toolchain,
      rulego_server: .abi.rulego_server, rulego_core: .abi.rulego_core,
      module_graph: .abi.module_graph, build: .abi.build
    }
  ' "${lock}" || die "unsupported build architecture: ${arch}"
}

render_sdk_env() {
  local arch=${1:?SDK environment architecture is required}
  local host_id=${2:-plugin}
  local build_json value
  build_json=$(render_build "${arch}")
  jq -e --arg host_id "${host_id}" '.build.hosts | any(.id == $host_id)' <<<"${build_json}" >/dev/null \
    || die "unknown host variant: ${host_id}"
  while IFS=$'\t' read -r name value; do
    printf '%s=%q\n' "${name}" "${value}"
  done < <(jq -r '
    [
      ["ABI_ID", .abi_id],
      ["LOCK_DIGEST", .lock_digest],
      ["GO_VERSION", .go.version],
      ["GOOS", .go.goos],
      ["GOARCH", .target.goarch],
      ["CGO_ENABLED", (if .go.cgo_enabled then "1" else "0" end)],
      ["GOENV", .go.environment.GOENV],
      ["GOTOOLCHAIN", .go.environment.GOTOOLCHAIN],
      ["GOFLAGS", .go.environment.GOFLAGS],
      ["GOEXPERIMENT", .go.environment.GOEXPERIMENT],
      ["CGO_CFLAGS", .go.environment.CGO_CFLAGS],
      ["CGO_CPPFLAGS", .go.environment.CGO_CPPFLAGS],
      ["CGO_CXXFLAGS", .go.environment.CGO_CXXFLAGS],
      ["CGO_LDFLAGS", .go.environment.CGO_LDFLAGS],
      ["TUNING_KEY", (.target.tuning | keys[0])],
      ["TUNING_VALUE", (.target.tuning | .[keys[0]])],
      ["CC", .target.cc],
      ["CXX", .target.cxx],
      ["CC_VERSION", .toolchain.cc_version],
      ["LINKER_COMMAND", .toolchain.linker_command],
      ["LINKER_IDENTITY", .toolchain.linker],
      ["LINKER_VERSION", .toolchain.linker_version],
      ["SERVER_REVISION", .rulego_server.revision],
      ["SERVER_GO_MOD_SHA256", .rulego_server.go_mod_sha256],
      ["SERVER_GO_SUM_SHA256", .rulego_server.go_sum_sha256],
      ["CORE_MODULE", .rulego_core.module],
      ["CORE_VERSION", .rulego_core.version],
      ["HOST_MODE", .build.host_mode],
      ["PLUGIN_MODE", .build.plugin_mode],
      ["HOST_ID", $host_id],
      ["HOST_TAGS", (.build.hosts[] | select(.id == $host_id) | .tags | join(","))],
      ["HOST_VARIANTS", ([.build.hosts[] | (.id + "=" + (.tags | join(",")))] | join(";"))],
      ["HOST_FLAGS", (.build.host_flags | join(" "))],
      ["HOST_LDFLAGS", (.build.host_ldflags | join(" "))],
      ["HOST_WORKSPACE", .build.host_workspace],
      ["PLUGIN_FLAGS", (.build.plugin_flags | join(" "))],
      ["PLUGIN_LDFLAGS", (.build.plugin_ldflags | join(" "))],
      ["PLUGIN_WORKSPACE", .build.plugin_workspace]
    ][] | @tsv
  # tr -d '\r' keeps emitted values identical to the CI (LF) output: the Windows
  # jq build ends every line with CR, and read would otherwise fold that CR into
  # $value, where printf %q escapes it into a literal "\r" in the env file.
  ' --arg host_id "${host_id}" <<<"${build_json}" | tr -d '\r')
}

render_compatibility_sdk() {
  local arch=${1:?compatibility SDK architecture is required}
  jq -ec --arg arch "${arch}" '
    .compatibility.previous_sdk as $sdk |
    $sdk.children[$arch] as $child |
    if $child == null then error("unsupported compatibility SDK architecture")
    else {
      abi_id: $sdk.abi_id,
      index_digest: $sdk.index_digest,
      child_digest: $child,
      reference: ($sdk.repository + "@" + $child)
    }
    end
  ' "${lock}" || die "unsupported compatibility SDK architecture: ${arch}"
}

render_metadata() {
  local variant=${1:?image variant is required}
  local arch=${2:-}
  local host_id=${3:-plugin}
  [[ ${variant} == plugin-sdk || ${variant} == plugin-runtime ]] || die "unknown image variant: ${variant}"
  if [[ -n ${arch} ]]; then
    jq -e --arg arch "${arch}" '.abi.go.targets | any(.goarch == $arch)' "${lock}" >/dev/null \
      || die "unsupported architecture: ${arch}"
  fi
  if [[ ${variant} == plugin-runtime ]]; then
    jq -e --arg host_id "${host_id}" '.abi.build.hosts | any(.id == $host_id)' "${lock}" >/dev/null \
      || die "unknown host variant: ${host_id}"
  fi
  jq -c --arg lock_digest "$(lock_digest)" --arg variant "${variant}" --arg arch "${arch}" --arg host_id "${host_id}" '
    (.abi.build.hosts[] | select(.id == $host_id)) as $host |
    {
      "io.rulego.abi.id": .abi_id,
      "io.rulego.abi.lock.digest": $lock_digest,
      "io.rulego.image.variant": $variant,
      "io.rulego.server.release": .abi.rulego_server.release_version,
      "io.rulego.server.revision": .abi.rulego_server.revision,
      "io.rulego.core.version": .abi.rulego_core.version,
      "io.rulego.core.revision": .abi.rulego_core.revision,
      "io.rulego.go.version": .abi.go.version,
      "io.rulego.libc.family": .abi.native.libc,
      "io.rulego.libc.minimum": .abi.native.minimum_version,
      "org.opencontainers.image.version": (if $variant == "plugin-sdk" then .abi_id else .abi.rulego_server.release_version + $host.tag_suffix end)
    } + if $variant == "plugin-runtime" then {
      "io.rulego.abi.host": $host.id
    } else {
    } end + if $arch == "" then
      {"io.rulego.abi.platforms": ([.abi.go.targets[].platform] | join(","))}
    else
      {"io.rulego.abi.platform": (.abi.go.targets[] | select(.goarch == $arch) | .platform)}
    end
  ' "${lock}"
}

render_tags() {
  # Release stays the default because publication must not claim tags from a lock that is
  # still measuring. The candidate mode exists for the allocatability dry-run, which has to
  # ask the same question about names while `release.state` is measurement, that is before
  # any of this is publishable at all.
  validate_lock "${1:---release}"
  jq -c '. as $root | {
    sdk: (.release.sdk_image + ":" + .abi_id),
    runtime: (reduce .abi.build.hosts[] as $host ({};
      .[$host.id] = ($root.release.runtime_image + ":" + $root.abi.rulego_server.release_version + $host.tag_suffix)))
  }' "${lock}"
}

case ${1:-} in
  validate)
    [[ $# == 2 ]] || usage
    validate_lock "$2"
    ;;
  render)
    case ${2:-} in
      id) [[ $# == 2 ]] || usage; validate_lock --candidate; jq -er '.abi_id' "${lock}" ;;
      lock-digest) [[ $# == 2 ]] || usage; validate_lock --candidate; lock_digest ;;
      manifest) [[ $# == 2 ]] || usage; validate_lock --candidate; canonical_manifest ;;
      matrix) [[ $# == 2 ]] || usage; validate_lock --candidate; render_matrix ;;
      ci) [[ $# == 2 ]] || usage; validate_lock --candidate; render_ci ;;
      editor) [[ $# == 2 ]] || usage; validate_lock --candidate; render_editor ;;
      build) [[ $# == 3 ]] || usage; validate_lock --candidate; render_build "$3" ;;
      sdk-env) [[ $# == 3 || $# == 4 ]] || usage; validate_lock --candidate; render_sdk_env "$3" "${4:-plugin}" ;;
      compatibility-sdk) [[ $# == 3 ]] || usage; validate_lock --candidate; render_compatibility_sdk "$3" ;;
      size-limit)
        [[ $# == 3 || $# == 4 ]] || usage
        validate_lock --candidate
        if [[ $# == 3 ]]; then
          jq -ec --arg arch "$3" '.release.size_limits[$arch] // error("unsupported size-limit architecture")' "${lock}"
        else
          jq -ec --arg arch "$3" --arg host_id "$4" '
            .release.size_limits[$arch] as $limits |
            if $limits == null then error("unsupported size-limit architecture")
            elif ($limits.runtime[$host_id] == null) then error("unknown host variant")
            else {sdk: $limits.sdk, runtime: $limits.runtime[$host_id]}
            end
          ' "${lock}"
        fi
        ;;
      metadata) [[ $# == 3 || $# == 4 || $# == 5 ]] || usage; validate_lock --candidate; render_metadata "$3" "${4:-}" "${5:-plugin}" ;;
      tags)
        [[ $# == 2 || $# == 3 ]] || usage
        render_tags "${3:---release}"
        ;;
      *) usage ;;
    esac
    ;;
  *) usage ;;
esac
