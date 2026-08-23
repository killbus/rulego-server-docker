# RuleGo Server container images

This repository packages the official, CI-built [RuleGo](https://github.com/rulego/rulego)
server release binaries as small, non-root multi-platform container images. It
does not rebuild RuleGo from source.

## Usage

Pull a versioned standard image:

```bash
docker pull ghcr.io/killbus/rulego-server:v0.37.0
docker run --rm -p 9090:9090 \
  -v rulego-data:/app/data \
  ghcr.io/killbus/rulego-server:v0.37.0
```

Open <http://localhost:9090/editor/> after the server starts. Use the
all-components variant when its additional RuleGo components are required:

```bash
docker run --rm -p 9090:9090 \
  -v rulego-data:/app/data \
  ghcr.io/killbus/rulego-server:v0.37.0-all
```

The image runs as UID/GID `65532:65532`, exposes TCP port 9090, uses
`/app/config.conf` by default, and writes persistent rules and logs beneath
`/app/data`. Mount that directory as a volume. Both `linux/amd64` and
`linux/arm64` are published in every image index.

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

## Maintenance checks

The preparation script requires Bash, curl, jq, Python 3, tar, and GNU
coreutils. To validate both sets of upstream payloads without building or
starting containers:

```bash
scripts/fetch-release.sh v0.37.0 standard
scripts/fetch-release.sh v0.37.0 all
```

Run the local static and failure-injection gates with:

```bash
bash -n scripts/*.sh tests/*.sh
shellcheck scripts/*.sh tests/*.sh
actionlint .github/workflows/publish.yml
tests/run.sh
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
