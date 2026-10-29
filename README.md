# RuleGo Server container images

This repository packages the official, CI-built [RuleGo](https://github.com/rulego/rulego)
server release binaries as small, non-root multi-platform container images.
Those standard and all-components images never rebuild RuleGo from source. A
separate Plugin ABI stream builds a lock-pinned, plugin-capable host and SDK;
it never feeds its source-built bytes into the standard or all tags.

## Usage

Pull a versioned standard image:

```bash
docker pull ghcr.io/killbus/rulego-server:v1.0.0
docker run --rm -p 9090:9090 \
  -v rulego-data:/app/data \
  ghcr.io/killbus/rulego-server:v1.0.0
```

Open <http://localhost:9090/editor/> after the server starts. Use the
all-components variant when its additional RuleGo components are required:

```bash
docker run --rm -p 9090:9090 \
  -v rulego-data:/app/data \
  ghcr.io/killbus/rulego-server:v1.0.0-all
```

The image runs as UID/GID `65532:65532`, exposes TCP port 9090, uses
`/app/config.conf` by default, and writes persistent rules and logs beneath
`/app/data`. Mount that directory as a volume. Both `linux/amd64` and
`linux/arm64` are published in every image index.

## Plugin ABI images

[`plugin-abi.lock`](plugin-abi.lock) is the host distributor's single machine
authority for the Plugin ABI. It owns the exact Go and native toolchains,
Linux targets, glibc floor, RuleGo Server and Core revisions, module graph,
build inputs, image names, and release policy. The current
contract uses Go 1.25.0, `CGO_ENABLED=1`, glibc 2.34 or newer, RuleGo Server
release `v1.0.0` at source revision
`45d1a6c4e1af594d7319dd11df9fa58bd48fd0e0`, and RuleGo Core
`v1.0.0`. The source revision is the commit
peeled from that formal release tag; the ABI ID additionally identifies the
complete build contract, while an OCI digest identifies the resulting image.

The ownership chain is:

```text
host distributor -> plugin-abi.lock -> SDK image digest -> plugin .so + ABI sidecar
                                  \-> runtime image digest -> loads the external .so
```

The SDK discovery tag is `rulego-plugin-sdk:<abi_id>`. One SDK serves both
plugin-capable runtime hosts:

- `rulego-server:v1.0.0-plugin` is the standard host without optional component tags.
- `rulego-server:v1.0.0-ai-plugin` is built with `with_ai` and includes `ai/agent`.

The same ABI-compatible plugin can be loaded by either runtime. Consumers
execute the OCI digests recorded in the workflow's `plugin-abi-release.json`;
canonical tags are first-writer immutable and there are no moving aliases.
An `-all-plugin` host is reserved for a later release and is not produced by
this contract.

Given a reviewed release record downloaded from the matching workflow run, the
minimal build is:

```bash
SDK_REF=$(jq -er '.sdk | select(test("@sha256:[0-9a-f]{64}$"))' plugin-abi-release.json)
RUNTIME_HOST=${RUNTIME_HOST:-plugin}
RUNTIME_REF=$(jq -er --arg host "$RUNTIME_HOST" \
  '.runtime[$host] | select(test("@sha256:[0-9a-f]{64}$"))' plugin-abi-release.json)
ABI_ID=$(jq -er '.abi_id' plugin-abi-release.json)
LOCK_DIGEST=$(jq -er '.lock_digest' plugin-abi-release.json)

install -d -m 0777 dist
docker run --rm --platform linux/amd64 \
  -v "$PWD:/workspace:ro" -v "$PWD/dist:/output" \
  "$SDK_REF" ./plugin /output/plugin.so
PLUGIN_SHA256=$(sha256sum dist/plugin.so | awk '{print $1}')
jq -e --arg abi "$ABI_ID" --arg lock "$LOCK_DIGEST" --arg sha "$PLUGIN_SHA256" \
  '.abi_id == $abi and .platform == "linux/amd64" and
   .lock_digest == $lock and .plugin_sha256 == $sha' dist/plugin.so.abi.json
```

Install only a sidecar-verified plugin in the runtime's persisted data path:

```bash
mkdir -p data/plugins
cp dist/plugin.so data/plugins/
docker run --rm --platform linux/amd64 -p 9090:9090 \
  -v "$PWD/data:/app/data" \
  "$RUNTIME_REF"
```

The complete canonical lock is available in both images at
`/usr/share/rulego/plugin-abi.json`. OCI index annotations expose the ordered
platform set and common ABI fields; each child config labels only its own
platform. Plugin repositories may add plugin-only modules, but must explicitly
align shared dependencies with the manifest; the SDK rejects mismatched host
module identities and never edits the plugin checkout. Plugins are installed
externally under `/app/data/plugins`; no business plugin is bundled in the
runtime image.
The digest-pinned SDK compiles the host and exports a root filesystem. The
runtime recipe copies only that root filesystem into the pinned distroless
base, so SDK layers and build tools never enter the runtime image.

## Tags and upstream assets

For an upstream release `vX.Y.Z`, tag-to-asset selection is exact:

| Image tag | Variant | amd64 asset | arm64 asset |
| --- | --- | --- | --- |
| `vX.Y.Z` | standard | `rulego-server-linux-amd64.tar.gz` | `rulego-server-linux-arm64.tar.gz` |
| `vX.Y.Z-all` | all components | `rulego-server-all-linux-amd64.tar.gz` | `rulego-server-all-linux-arm64.tar.gz` |
| `latest` | current stable standard | `rulego-server-linux-amd64.tar.gz` | `rulego-server-linux-arm64.tar.gz` |
| `latest-all` | current stable all components | `rulego-server-all-linux-amd64.tar.gz` | `rulego-server-all-linux-arm64.tar.gz` |

Version tags are the reproducible choice. `latest` and `latest-all` point only
to the current stable upstream release. A manual historical build never moves
either alias backward.

## Verification model

The publishing job establishes a continuous two-link trust chain for every
variant and architecture:

1. It obtains the exact asset URL and `sha256:<hex>` digest from the stable
   `rulego/rulego` GitHub release API response. A missing digest, duplicate or
   missing asset, draft/prerelease, unsafe archive entry, or checksum mismatch
   stops the job before extraction and publication.
2. It hashes the executable extracted from that verified archive, exports the
   built image filesystem, and proves `/app/rulego-server` has the same hash.
   After pushing, it pulls each platform image and repeats the comparison.

GitHub publishes the digest of the compressed release archive, not the digest
of the executable inside it. These two checks deliberately connect those
different objects rather than incorrectly comparing their hashes directly.
The complete verified archive payload—configuration, node-pool data, and
editor assets—is retained.

The runtime base is the digest-pinned multi-architecture
`gcr.io/distroless/static-debian13:nonroot` image. It has CA certificates and
the non-root identity required at runtime, but no shell, package manager,
compiler, or RuleGo source checkout. BuildKit also publishes provenance and
SBOM attestations.

## Publishing

[The publishing workflow](.github/workflows/publish.yml) runs daily at 04:17
UTC. It discovers GitHub's latest stable RuleGo release and does nothing when
both version tags and both moving aliases already exist and resolve to their
matching indexes. Publication is serialized so scheduled and manual runs
cannot race.

Maintainers can also run **Publish RuleGo Server images** from the Actions tab:

- `version` is required and must be an existing, published, non-prerelease
  `vX.Y.Z` RuleGo release.
- `force` rebuilds/repairs the version tags even if complete indexes already
  exist. It still cannot move `latest` aliases unless the requested version is
  the current upstream stable release.

The workflow derives the GHCR owner from the repository context, logs in with
the built-in `GITHUB_TOKEN`, and needs only `contents: read` and
`packages: write`. No personal access token is used. All third-party actions
are pinned to reviewed commit SHAs; their release versions are recorded beside
each use.

The independent [Plugin ABI verification workflow](.github/workflows/plugin-abi.yml)
calls one repository command on each native amd64 and arm64 runner. That
command uses a job-local registry, consumes the SDK by digest, exports the
matching host rootfs, builds both runtime hosts, verifies their `ai/agent`
component difference, loads a host-owned ABI probe in each, proves
wrong-architecture, wrong-ABI, and missing-libc failures, and records image
sizes. The release record stores runtime digests under `.runtime.plugin` and
`.runtime["ai-plugin"]`. Business-plugin repositories consume the SDK digest and own their
artifact compatibility checks. Ordinary push and pull-request runs neither
request package-write permission nor move images between jobs.

The lock is release-ready only after a maintainer reviews a successful
candidate size report, records positive ceilings, and reruns the full matrix.
External publication uses the separate
[Plugin ABI publication workflow](.github/workflows/plugin-abi-publish.yml).
It requires an explicit `publish=true` manual dispatch and approval of the
`plugin-abi-release` environment. Native jobs stage their verified images with
commit-qualified tags; the release job creates two-platform indexes without
rebuilding, enforces first-writer immutable canonical tags, and verifies the
returned GHCR digests before producing its release record.

## Maintenance checks

The preparation script requires Bash, curl, jq, Python 3, tar, and GNU
coreutils. To validate both sets of upstream payloads without building or
starting containers:

```bash
scripts/fetch-release.sh v1.0.0 standard
scripts/fetch-release.sh v1.0.0 all
```

Run the local static and failure-injection gates with:

```bash
bash -n scripts/*.sh tests/*.sh
shellcheck scripts/*.sh tests/*.sh
actionlint .github/workflows/publish.yml
actionlint .github/workflows/plugin-abi.yml
actionlint .github/workflows/plugin-abi-publish.yml
tests/run.sh
scripts/plugin-abi.sh validate --candidate
```

The publishing workflow configures QEMU and Buildx, runs
`scripts/verify-build.sh` before publication, and runs
`scripts/verify-published.sh` afterward. These CI-only gates perform the
two-platform builds, non-root HTTP smoke tests, runtime-content checks,
manifest checks, and executable digest comparisons.

Transient API, registry, and download failures—including disconnected streams,
HTTP 429/5xx responses, and GitHub rate-limit responses—are retried with
bounded exponential backoff. Deterministic failures such as invalid versions,
ordinary 4xx responses, or checksum mismatches fail immediately.
