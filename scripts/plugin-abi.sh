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
       scripts/plugin-abi.sh render <id|lock-digest|manifest|manifest-digest|matrix|ci|editor>
       scripts/plugin-abi.sh render build <amd64|arm64>
       scripts/plugin-abi.sh render sdk-env <amd64|arm64>
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

canonical_recipe() {
  jq -S -c '.distribution.recipe' "${lock}" | tr -d '\r'
}

calculated_recipe_id() {
  printf 'recipe-%s\n' "$(canonical_recipe | sha256sum | awk '{print $1}')"
}

# The bytes the lock file is, whole. This is provenance about a file in a repository, and it goes in
# the evidence, the release record and the probe record. It does not go in image bytes: a hash of the
# whole lock is a hash of the release policy too, so baking it would let `state`, a ceiling or a
# runner label move a published artifact while its identity stayed exactly where it was.
canonical_lock() {
  jq -S -c . "${lock}" | tr -d '\r'
}

lock_digest() {
  canonical_lock | sha256sum | awk '{print "sha256:" $1}'
}

# The bytes the identity is. `abi_id` is the digest of `.abi`, so a reader holding this document can
# check the name the image carries against the content it claims, without the lock's release policy
# being part of what is checked. The two paths the file is staged at, and every verifier that
# compares it, read these bytes; nothing outside `.abi` reaches an image through them.
canonical_manifest() {
  jq -S -c '{abi_id, abi}' "${lock}" | tr -d '\r'
}

abi_manifest_digest() {
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
    exact_keys(["schema_version", "abi_id", "recipe_id", "abi", "distribution"]) and
    .schema_version == 2 and
    (.abi_id | test("^abi-[0-9a-f]{64}$")) and
    (.recipe_id | test("^recipe-[0-9a-f]{64}$")) and
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
    (.abi.rulego_server | exact_keys(["repository", "release_version", "revision", "go_mod_sha256", "go_sum_sha256"])) and
    (.abi.rulego_server.repository | test("^https://github\\.com/[^/]+/[^/]+$")) and
    (.abi.rulego_server.release_version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.abi.rulego_server.revision | revision) and
    (.abi.rulego_server.go_mod_sha256 | sha256) and (.abi.rulego_server.go_sum_sha256 | sha256) and
    (.abi.rulego_core | exact_keys(["module", "version", "revision"])) and
    (.abi.rulego_core.module | nonempty) and (.abi.rulego_core.version | nonempty) and
    (.abi.rulego_core.revision | revision) and
    ((.abi.rulego_core.version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) or
     (.abi.rulego_core.version | endswith($root.abi.rulego_core.revision[0:12]))) and
    (.abi.module_graph | exact_keys(["list_sha256", "graph_sha256", "replacements"])) and
    (.abi.module_graph.list_sha256 | sha256) and (.abi.module_graph.graph_sha256 | sha256) and
    .abi.module_graph.replacements == [] and
    (.abi.build | exact_keys(["host_mode", "plugin_mode", "host_flags", "plugin_flags", "host_ldflags", "plugin_ldflags", "host_workspace"])) and
    .abi.build.host_mode == "exe" and .abi.build.plugin_mode == "plugin" and
    .abi.build.host_flags == ["-trimpath"] and
    .abi.build.plugin_flags == ["-trimpath", "-buildvcs=false"] and .abi.build.host_ldflags == [] and
    .abi.build.plugin_ldflags == [] and .abi.build.host_workspace == "off" and
    (.distribution | exact_keys(["hosts", "recipe", "compatibility", "release"])) and
    (.distribution.hosts == [
      {"id":"plugin","tags":[],"tag_suffix":"-plugin"},
      {"id":"ai-plugin","tags":["with_ai"],"tag_suffix":"-ai-plugin"},
      {"id":"all-plugin","tags":["with_all"],"tag_suffix":"-all-plugin"}
    ]) and
    ([.distribution.hosts[] | exact_keys(["id", "tags", "tag_suffix"])] | all) and
    (.distribution.recipe | exact_keys(["manifest_path", "reproducible_epoch", "editor_payload", "files"])) and
    (.distribution.recipe.manifest_path | startswith("/") and endswith(".json")) and
    (.distribution.recipe.reproducible_epoch | type == "number" and . == floor and . >= 0) and
    (.distribution.recipe.editor_payload | exact_keys(["repository", "version", "asset"])) and
    .distribution.recipe.editor_payload.repository == $root.abi.rulego_server.repository and
    .distribution.recipe.editor_payload.version == $root.abi.rulego_server.release_version and
    (.distribution.recipe.editor_payload.asset | exact_keys(["name", "sha256"])) and
    (.distribution.recipe.editor_payload.asset.name | test("^[A-Za-z0-9._-]+\\.tar\\.gz$")) and
    (.distribution.recipe.editor_payload.asset.sha256 | sha256) and
    (.distribution.recipe.files | length > 0) and
    ([.distribution.recipe.files[] | exact_keys(["path", "sha256"])] | all) and
    ([.distribution.recipe.files[].path] | unique | length) == (.distribution.recipe.files | length) and
    ([.distribution.recipe.files[] | .path as $p | ($p | test("^[A-Za-z0-9._/-]+$")) and ($p | startswith("/") | not) and ($p | contains("..") | not)] | all) and
    ([.distribution.recipe.files[].sha256 | sha256] | all) and
    (.distribution.compatibility | exact_keys(["previous_sdk"])) and
    (.distribution.compatibility.previous_sdk |
      exact_keys(["abi_id", "repository", "index_digest", "children"])) and
    (.distribution.compatibility.previous_sdk.abi_id | test("^abi-[0-9a-f]{64}$")) and
    .distribution.compatibility.previous_sdk.abi_id != .abi_id and
    (.distribution.compatibility.previous_sdk.repository |
      test("^ghcr\\.io/[a-z0-9]+([._-][a-z0-9]+)*/[a-z0-9]+([._-][a-z0-9]+)*$")) and
    (.distribution.compatibility.previous_sdk.index_digest | digest) and
    (.distribution.compatibility.previous_sdk.children |
      (keys_unsorted | sort) == ([$root.abi.go.targets[].goarch] | sort)) and
    ([.distribution.compatibility.previous_sdk.children[] | digest] | all) and
    (.distribution.release | exact_keys(["state", "sdk_image", "runtime_image", "ci", "size_limits"])) and
    (.distribution.release.state == "measurement" or .distribution.release.state == "ready") and
    ([.distribution.release.sdk_image, .distribution.release.runtime_image] | all(test("^[a-z0-9]+([._-][a-z0-9]+)*$"))) and
    (.distribution.release.ci | exact_keys(["runners"])) and
    (.distribution.release.ci.runners | exact_keys(["amd64", "arm64"])) and
    ([.distribution.release.ci.runners.amd64, .distribution.release.ci.runners.arm64] | all(nonempty)) and
    (.distribution.release.size_limits | exact_keys(["amd64", "arm64"])) and
    ([.distribution.release.size_limits[] | exact_keys(["sdk", "runtime"])] | all) and
    ([.distribution.release.size_limits[].sdk | exact_keys(["compressed", "uncompressed"])] | all) and
    ([.distribution.release.size_limits[].runtime |
      (keys_unsorted | sort) == ([$root.distribution.hosts[].id] | sort)] | all) and
    ([.distribution.release.size_limits[].runtime[] | exact_keys(["compressed", "uncompressed"])] | all)
  ' "${lock}" >/dev/null || die 'Plugin ABI lock schema or values are invalid'

  local expected actual expected_recipe actual_recipe path digest file state
  expected=$(calculated_abi_id)
  actual=$(jq -er '.abi_id' "${lock}")
  [[ ${actual} == "${expected}" ]] || die "stale abi_id: expected ${expected}, found ${actual}"

  expected_recipe=$(calculated_recipe_id)
  actual_recipe=$(jq -er '.recipe_id' "${lock}")
  [[ ${actual_recipe} == "${expected_recipe}" ]] || die "stale recipe_id: expected ${expected_recipe}, found ${actual_recipe}"

  while IFS=$'\t' read -r path digest; do
    file="${repository_root}/${path}"
    [[ -f ${file} ]] || die "recipe file is missing: ${path}"
    actual=$(sha256sum "${file}" | awk '{print $1}')
    [[ ${actual} == "${digest}" ]] || die "recipe file digest is stale: ${path}"
  done < <(jq -r '.distribution.recipe.files[] | [.path, .sha256] | @tsv' "${lock}")

  state=$(jq -er '.distribution.release.state' "${lock}")
  if [[ ${mode} == --candidate ]]; then
    if [[ ${state} == measurement ]]; then
      jq -e '[.distribution.release.size_limits | .. | select(type != "object")] | all(. == null)' "${lock}" >/dev/null \
        || die 'measurement state permits only null size ceilings'
    else
      jq -e '[.distribution.release.size_limits | .. | select(type != "object")] | all(type == "number" and (floor == .) and . > 0)' "${lock}" >/dev/null \
        || die 'ready state requires positive integer size ceilings'
    fi
  else
    [[ ${state} == ready ]] || die 'release validation requires distribution.release.state=ready'
    jq -e '[.distribution.release.size_limits | .. | select(type != "object")] | all(type == "number" and (floor == .) and . > 0)' "${lock}" >/dev/null \
      || die 'release validation requires positive integer size ceilings'
  fi
}

render_matrix() {
  jq -c '{include: [.abi.go.targets[] as $target | {
    goarch: $target.goarch, platform: $target.platform,
    runner: .distribution.release.ci.runners[$target.goarch],
    tuning_key: ($target.tuning | keys[0]),
    tuning_value: ($target.tuning | .[keys[0]])
  }]}' "${lock}"
}

render_ci() {
  jq -c --arg lock_digest "$(lock_digest)" '{
    abi_id, recipe_id, lock_digest: $lock_digest, go_version: .abi.go.version,
    libc_minimum: .abi.native.minimum_version,
    sdk_base: .abi.native.sdk_base, runtime_base: .abi.native.runtime_base,
    server_repository: .abi.rulego_server.repository,
    server_release: .abi.rulego_server.release_version,
    server_revision: .abi.rulego_server.revision,
    manifest_path: .distribution.recipe.manifest_path, release_state: .distribution.release.state,
    reproducible_epoch: .distribution.recipe.reproducible_epoch,
    sdk_image: .distribution.release.sdk_image, runtime_image: .distribution.release.runtime_image,
    hosts: .distribution.hosts,
    matrix: {include: [.abi.go.targets[] as $target | {
      goarch: $target.goarch, platform: $target.platform,
      runner: .distribution.release.ci.runners[$target.goarch],
      tuning_key: ($target.tuning | keys[0]),
      tuning_value: ($target.tuning | .[keys[0]])
    }]}
  }' "${lock}"
}

render_editor() {
  jq -c '.distribution.recipe.editor_payload' "${lock}"
}

render_build() {
  local arch=${1:?build architecture is required}
  jq -ec --arg arch "${arch}" --arg lock_digest "$(lock_digest)" \
    --arg abi_manifest_digest "$(abi_manifest_digest)" '
    (.abi.go.targets[] | select(.goarch == $arch)) as $target |
    (.abi.native.toolchains[] | select(.goarch == $arch)) as $toolchain |
    {
      abi_id, recipe_id, lock_digest: $lock_digest,
      # What the image is allowed to know about its own lock: the identity document and its digest.
      # `lock_digest` stays here for the evidence file, which is written outside the image, and is
      # deliberately not exported into `render sdk-env`, because that file is copied into the image.
      abi_manifest_digest: $abi_manifest_digest,
      manifest_path: .distribution.recipe.manifest_path,
      reproducible_epoch: .distribution.recipe.reproducible_epoch,
      go: (.abi.go | del(.targets)), target: $target,
      native: (.abi.native | del(.toolchains)), toolchain: $toolchain,
      rulego_server: .abi.rulego_server, rulego_core: .abi.rulego_core,
      module_graph: .abi.module_graph, build: .abi.build
    }
  ' "${lock}" || die "unsupported build architecture: ${arch}"
}

render_sdk_env() {
  local arch=${1:?SDK environment architecture is required}
  local build_json value
  build_json=$(render_build "${arch}")
  while IFS=$'\t' read -r name value; do
    printf '%s=%q\n' "${name}" "${value}"
  done < <(jq -r '
    [
      ["ABI_ID", .abi_id],
      # The digest of what the image actually carries. The whole-lock digest is not exported here:
      # this file is copied into the SDK, so a value that covers `state`, the ceilings and the runner
      # labels would put release policy inside published bytes and let a policy edit move an artifact
      # whose identity did not change.
      ["ABI_MANIFEST_DIGEST", .abi_manifest_digest],
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
      ["SERVER_GO_MOD_SHA256", .rulego_server.go_mod_sha256],
      ["SERVER_GO_SUM_SHA256", .rulego_server.go_sum_sha256],
      ["CORE_MODULE", .rulego_core.module],
      ["CORE_VERSION", .rulego_core.version],
      ["HOST_MODE", .build.host_mode],
      ["PLUGIN_MODE", .build.plugin_mode],
      ["HOST_FLAGS", (.build.host_flags | join(" "))],
      ["HOST_LDFLAGS", (.build.host_ldflags | join(" "))],
      ["HOST_WORKSPACE", .build.host_workspace],
      ["PLUGIN_FLAGS", (.build.plugin_flags | join(" "))],
      ["PLUGIN_LDFLAGS", (.build.plugin_ldflags | join(" "))]
    ][] | @tsv
  # The trailing CR strip keeps emitted values identical to the CI (LF) output: the Windows
  # jq build ends every line with CR, and read would otherwise fold that CR into
  # $value, where printf %q escapes it into a literal "\r" in the env file.
  ' <<<"${build_json}" | tr -d '\r')
}

render_compatibility_sdk() {
  local arch=${1:?compatibility SDK architecture is required}
  jq -ec --arg arch "${arch}" '
    .distribution.compatibility.previous_sdk as $sdk |
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
  local host_id=${3:-}
  local host_suffix='' host_tags=''
  [[ ${variant} == plugin-sdk || ${variant} == plugin-runtime ]] || die "unknown image variant: ${variant}"
  if [[ -n ${arch} ]]; then
    jq -e --arg arch "${arch}" '.abi.go.targets | any(.goarch == $arch)' "${lock}" >/dev/null \
      || die "unsupported architecture: ${arch}"
  fi
  if [[ ${variant} == plugin-runtime ]]; then
    [[ -n ${host_id} ]] || die 'plugin-runtime metadata requires a host id'
    jq -e --arg host_id "${host_id}" '.distribution.hosts | any(.id == $host_id)' "${lock}" >/dev/null \
      || die "unknown host variant: ${host_id}"
    host_suffix=$(jq -er --arg host "${host_id}" '.distribution.hosts[] | select(.id == $host) | .tag_suffix' "${lock}")
    host_tags=$(jq -er --arg host "${host_id}" '.distribution.hosts[] | select(.id == $host) | .tags | join(",")' "${lock}")
  else
    [[ -z ${host_id} ]] || die 'plugin-sdk metadata takes no host id'
  fi
  jq -c --arg manifest_digest "$(abi_manifest_digest)" --arg variant "${variant}" --arg arch "${arch}" \
    --arg host_id "${host_id}" --arg host_suffix "${host_suffix}" --arg host_tags "${host_tags}" '
    {
      "io.rulego.abi.id": .abi_id,
      "io.rulego.recipe.id": .recipe_id,
      # The digest of the identity document the image carries, not of the lock file it was rendered
      # from. A label is part of the child config, so a whole-lock digest here would put release
      # policy -- `state`, the ceilings, the runner labels -- inside published bytes, and a policy
      # edit would then move an artifact whose identity had not changed.
      "io.rulego.abi.manifest.digest": $manifest_digest,
      "io.rulego.image.variant": $variant,
      "io.rulego.server.release": .abi.rulego_server.release_version,
      "io.rulego.server.revision": .abi.rulego_server.revision,
      "io.rulego.core.version": .abi.rulego_core.version,
      "io.rulego.core.revision": .abi.rulego_core.revision,
      "io.rulego.go.version": .abi.go.version,
      "io.rulego.libc.family": .abi.native.libc,
      "io.rulego.libc.minimum": .abi.native.minimum_version,
      "org.opencontainers.image.version": (if $variant == "plugin-sdk" then .abi_id else .abi.rulego_server.release_version + $host_suffix end),
      # The three OCI-standard annotations describe the source these bytes were compiled from, which
      # is the upstream revision the lock records, not the commit of this packaging repository that
      # ran the build. A per-commit value in the image config moves the child digest on every build,
      # so republishing an unchanged contract never compares equal and every rerun reads as a
      # conflict. Which commit packaged a release is recorded three times outside the bytes: the
      # staging tag name, the release record, and the SLSA attestation.
      "org.opencontainers.image.source": .abi.rulego_server.repository,
      "org.opencontainers.image.revision": .abi.rulego_server.revision,
      "org.opencontainers.image.licenses": "Apache-2.0"
    } + if $variant == "plugin-runtime" then {
      "io.rulego.host": $host_id,
      "io.rulego.host.tags": $host_tags
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
  #
  # Two tracks, because one name cannot be both a promise and an address:
  #   canonical -- `v1.0.0-<host>-r<recipe>-<rev>`, won by one build and never moved. The revision
  #                is the packaging commit, so a rebuild of the same commit re-wins the same name
  #                and compares equal to its own content, while any new commit arrives under a name
  #                nobody has spent. Adding a host variant, re-signing the lock or advancing the
  #                recipe therefore never has to wait for `release_version` to move upstream.
  #   alias     -- `v1.0.0-<host>`, the human-level name. It moves, and only through
  #                scripts/promote-alias.sh, which re-checks the canonical digest it was verified
  #                at and records where the alias pointed beforehand. Inside one `release_version`
  #                it always means "the newest verified build of this release line", and it never
  #                crosses an ABI break, because an ABI break is a new `release_version`.
  local mode=--release rev_arg=''
  case ${1:-} in
    --candidate|--release) mode=$1 ;;
    '') ;;
    *) [[ ${1} =~ ^[0-9a-f]{12}$ ]] || die 'render tags revision argument must be 12 lowercase hex characters'; rev_arg=$1 ;;
  esac
  validate_lock "${mode}"
  local name_revision=${rev_arg:-${PLUGIN_ABI_NAME_REVISION:-}}
  # `none` is the one legal value that is not a commit, and it means something specific: no build has
  # happened, so no per-build canonical name exists yet. The allocatability probe uses it to ask about
  # the names the lock already determines and to report the aliases as they stand, without inventing a
  # name a build could never own. A caller about to write must never use it, which is why publication
  # re-checks the shape and counts its plan against the lock rather than against this render.
  [[ ${name_revision} =~ ^[0-9a-f]{12}$ || ${name_revision} =~ ^[0-9a-f]{40}$ || ${name_revision} == none ]] ||
    die 'render tags needs a 12/40-character packaging revision, none, or PLUGIN_ABI_NAME_REVISION'
  local recipe_tag
  recipe_tag=$(jq -er '.recipe_id | sub("^recipe-"; "") | .[0:12]' "${lock}")
  jq -c --arg rev "${name_revision:0:12}" --arg recipe "${recipe_tag}" '. as $root | {
    sdk: (.distribution.release.sdk_image + ":" + .abi_id + "-r" + $recipe),
    runtime: (reduce .distribution.hosts[] as $host ({};
      .[$host.id] = {
        canonical: (if $rev == "none" then null
                    else $root.distribution.release.runtime_image + ":" + $root.abi.rulego_server.release_version + $host.tag_suffix + "-r" + $recipe + "-" + $rev
                    end),
        alias: ($root.distribution.release.runtime_image + ":" + $root.abi.rulego_server.release_version + $host.tag_suffix)
      }))
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
      recipe-id) [[ $# == 2 ]] || usage; validate_lock --candidate; jq -er '.recipe_id' "${lock}" ;;
      lock-digest) [[ $# == 2 ]] || usage; validate_lock --candidate; lock_digest ;;
      manifest) [[ $# == 2 ]] || usage; validate_lock --candidate; canonical_manifest ;;
      manifest-digest) [[ $# == 2 ]] || usage; validate_lock --candidate; abi_manifest_digest ;;
      matrix) [[ $# == 2 ]] || usage; validate_lock --candidate; render_matrix ;;
      ci) [[ $# == 2 ]] || usage; validate_lock --candidate; render_ci ;;
      editor) [[ $# == 2 ]] || usage; validate_lock --candidate; render_editor ;;
      build) [[ $# == 3 ]] || usage; validate_lock --candidate; render_build "$3" ;;
      sdk-env) [[ $# == 3 ]] || usage; validate_lock --candidate; render_sdk_env "$3" ;;
      compatibility-sdk) [[ $# == 3 ]] || usage; validate_lock --candidate; render_compatibility_sdk "$3" ;;
      size-limit)
        [[ $# == 3 || $# == 4 ]] || usage
        validate_lock --candidate
        if [[ $# == 3 ]]; then
          jq -ec --arg arch "$3" '.distribution.release.size_limits[$arch] // error("unsupported size-limit architecture")' "${lock}"
        else
          jq -ec --arg arch "$3" --arg host_id "$4" '
            .distribution.release.size_limits[$arch] as $limits |
            if $limits == null then error("unsupported size-limit architecture")
            elif $host_id == "sdk" then $limits.sdk
            elif ($limits.runtime[$host_id] == null) then error("unknown host variant")
            else {sdk: $limits.sdk, runtime: $limits.runtime[$host_id]}
            end
          ' "${lock}"
        fi
        ;;
      metadata) [[ $# == 3 || $# == 4 || $# == 5 ]] || usage; validate_lock --candidate; render_metadata "$3" "${4:-}" "${5:-}" ;;
      tags)
        [[ $# == 2 || $# == 3 ]] || usage
        render_tags "${3:-}"
        ;;
      *) usage ;;
    esac
    ;;
  *) usage ;;
esac
