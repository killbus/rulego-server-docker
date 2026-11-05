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

The SDK discovery tag is `rulego-plugin-sdk:<abi_id>-r<recipe12>`, and one SDK serves all three
plugin-capable hosts.

`<abi_id>` hashes only the `.abi` closure: the compiler, flags, module graph, native toolchain and
source revisions that decide whether `plugin.Open` succeeds. Hosts, compatibility, release policy
and image names are distribution, not ABI, and live under `.distribution`; adding or renaming a
host does not mint a new SDK identity.

The recipe is a second identity, `recipe_id`, hashing `.distribution.recipe`: the Dockerfiles, the
build scripts, the editor payload, the path the ABI manifest is written to, the reproducible epoch,
and the pinned file digests. A change that would alter published bytes without altering `.abi`
moves `recipe_id` and therefore every canonical name, while leaving `abi_id` alone. The two axes are
independent: an ABI change moves `abi_id`, a recipe change moves `recipe_id`, and a host or release
policy change moves neither.

The three plugin-capable hosts are `plugin`, built with no optional component tags; `ai-plugin`,
built with `with_ai` and including `ai/agent`; and `all-plugin`, built with `with_all`. The
`all-plugin` host is the optional-component union, not an alias of `ai-plugin`, and today its tags
include `ai/agent`. The same ABI-compatible plugin loads in any of the three runtimes.

Each host gets two public names, because one name cannot be a promise and an address at the same
time:

- the canonical name `rulego-server:v1.0.0-<host>-r<recipe12>-<packaging commit, first 12>` is won
  by one build and never moved. First-writer applies: a rerun of the same commit re-wins the same
  name and can compare equal to its own content, and any new commit or recipe arrives under a name
  nobody has spent.
- the alias `rulego-server:v1.0.0-plugin`, `rulego-server:v1.0.0-ai-plugin` or
  `rulego-server:v1.0.0-all-plugin` is the human-level name.
  It moves, and only through `scripts/promote-runtime-aliases.sh`, after the canonical build it will
  point at has been verified.
  Within one `release_version` it means "the newest verified build of this release line"; it cannot
  cross an ABI break, because an ABI break is a new `release_version`. Each promotion records where
  the alias pointed beforehand, which is what makes a bad move reversible rather than remembered.

Pin a digest from `plugin-abi-release.json`, or pin a canonical name. Pin an alias only when what you
want is "whatever this release line has currently verified", and then resolve it to a digest before
shipping. The SDK discovery tag `rulego-plugin-sdk:<abi_id>-r<recipe12>` has no alias: it is named by
the ABI and recipe it carries, so it is always the first kind of name.

Content, not the commit that packaged it, still decides what a published name holds. The image
annotations name the source revision recorded in the lock, and the commit that ran a build appears in
the canonical name, the staging tag names, the release record, and the per-build SLSA attestation --
never in the image bytes. So a rerun of one commit re-wins its own canonical name, compares equal to
the content already published there, and writes nothing. Equality is judged on the two
per-architecture images rather than on the multi-architecture index digest, which cannot repeat: the
index carries one provenance and one SBOM member per platform, and those describe the invocation that
wrote them.

The gate classifies every canonical name before it writes any of them, and a name it cannot explain
stops the release. A canonical name already held by an identity this lock accounts for is recorded as
`superseded`, skipped, and listed in the release record under `superseded_hosts` -- so the skipped
name is data rather than a recollection -- while a name held by an identity outside that set, or one
the registry could not answer for, refuses the batch. Names under the previous rule (`v1.0.0-plugin`
without a build suffix, spent by the 2026-10-22 and 2026-11-03 casts) are the aliases now: an earlier
cast keeps serving anyone who pins one, and the promotion step is the only thing that moves it.
Promotion refuses a host the gate skipped, so a pointer never advances past a build this release did
not claim.

The identities a release may account for are a set, not one slot: the lock's immediate predecessor
plus the earlier casts recorded in [`plugin-abi-history.json`](plugin-abi-history.json). One slot was
not enough -- measured after the first publication, `v1.0.0-plugin` and `v1.0.0-ai-plugin` were held
by two different identities, and accounting for either one alone left the other a collision that
refused a batch whose own names were all free. Each history entry names an `abi_id` and carries a
`reason`, because a predecessor list nobody can justify is indistinguishable from one written to pass
a gate. The file lives outside the lock because it is publication history, not a build input: it
records what was already shipped, and nothing a compiler reads depends on it. The manifest the images
carry is derived from `.abi` alone. `.distribution` reaches an image only through the recipe --
`reproducible_epoch`, `manifest_path` and the editor payload, all under `.distribution.recipe` -- and
a change to any of those moves `recipe_id`, not `abi_id`.

Given a reviewed release record downloaded from the matching workflow run, the
minimal build is:

```bash
SDK_REF=$(jq -er '.sdk | select(test("@sha256:[0-9a-f]{64}$"))' plugin-abi-release.json)
RUNTIME_HOST=${RUNTIME_HOST:-plugin}
RUNTIME_REF=$(jq -er --arg host "$RUNTIME_HOST" \
  '.runtime[$host] | select(test("@sha256:[0-9a-f]{64}$"))' plugin-abi-release.json)
ABI_ID=$(jq -er '.abi_id' plugin-abi-release.json)
ABI_MANIFEST_DIGEST=$(jq -er '.abi_manifest_digest' plugin-abi-release.json)

install -d -m 0777 dist
docker run --rm --platform linux/amd64 \
  -v "$PWD:/workspace:ro" -v "$PWD/dist:/output" \
  "$SDK_REF" ./plugin /output/plugin.so
PLUGIN_SHA256=$(sha256sum dist/plugin.so | awk '{print $1}')
jq -e --arg abi "$ABI_ID" --arg manifest "$ABI_MANIFEST_DIGEST" --arg sha "$PLUGIN_SHA256" \
  '.abi_id == $abi and .platform == "linux/amd64" and
   .abi_manifest_digest == $manifest and .plugin_sha256 == $sha' dist/plugin.so.abi.json
```

Install only a sidecar-verified plugin in the runtime's persisted data path:

```bash
mkdir -p data/plugins
cp dist/plugin.so data/plugins/
docker run --rm --platform linux/amd64 -p 9090:9090 \
  -v "$PWD/data:/app/data" \
  "$RUNTIME_REF"
```

The canonical identity document — `abi_id` plus the `.abi` closure it hashes —
is available in both images at
`/usr/share/rulego/plugin-abi.json`. OCI index annotations expose the ordered
platform set and common ABI fields; each child config labels only its own
platform. Plugin repositories may add plugin-only modules, but must explicitly
align shared dependencies with the manifest; the SDK rejects mismatched host
module identities and never edits the plugin checkout. Plugins are installed
externally under `/app/data/plugins`; no business plugin is bundled in the
runtime image.
What the images do *not* carry is the digest of the whole lock file. Release
policy — `state`, the size ceilings, the runner labels — lives in that file, and
hashing it into an image would let a policy edit move a published artifact whose
identity had not changed. The lock digest stays in the release record and in the
per-architecture evidence, outside the bytes; the digest an image can be checked
against is `abi_manifest_digest`, which covers the identity document only.
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

Both aliases move only after the version tag they point at has been verified, and
never at a digest that changed while verification ran. Each promotion writes a
record of where every alias pointed beforehand, which is what makes a bad move
reversible instead of something a maintainer repairs from memory.

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

Publication is two-phase, so those checks gate the public name rather than
merely follow it. `scripts/publish-index.sh` writes the immutable version tag
alone; the workflow then verifies that tag and reports the digest it verified;
`scripts/promote-alias.sh` re-reads the version tag and points the alias at that
digest only while it still holds exactly those bytes. Between the two writes the
new build is reachable by its immutable name, and a verification failure leaves
`latest` where it was. Before this, one command assembled the version tag and the
alias together, so `latest` advertised unverified content for as long as
verification took and stayed there if verification failed.

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
- `staging_only` builds the whole pipeline and publishes a single run-qualified
  `staging-<version>[-all]-<run id>` tag. It never writes a version tag or a
  moving alias, and it always builds even when the release tags are already
  complete, so it exercises the publish path for real without changing anything
  downstream users pull.

The workflow derives the GHCR owner from the repository context, logs in with
the built-in `GITHUB_TOKEN`, and needs only `contents: read` and
`packages: write`. No personal access token is used. All third-party actions
are pinned to reviewed commit SHAs; their release versions are recorded beside
each use.

The independent [Plugin ABI verification workflow](.github/workflows/plugin-abi.yml)
first runs `tests/run.sh` in one job, then calls one repository command on each
native amd64 and arm64 runner. `tests/run.sh` is fully offline—it needs neither
Docker, Go, nor `readelf`—and covers release preparation, repository and image
contracts, Plugin ABI rules, manifest validation, index assembly, and injected
failures. The native command uses a job-local registry, consumes the SDK by
digest, exports the
matching host rootfs, builds all three runtime hosts, verifies their `ai/agent`
component difference, loads a host-owned ABI probe in each, proves
wrong-architecture, wrong-ABI, and missing-libc failures, and records image
sizes. The release record stores runtime digests under `.runtime.plugin`,
`.runtime["ai-plugin"]`, and `.runtime["all-plugin"]`. Business-plugin repositories consume the SDK digest and own their
artifact compatibility checks. Ordinary push and pull-request runs neither
request package-write permission nor move images between jobs.

The lock is release-ready only after a maintainer reviews a successful
candidate size report, records positive ceilings, and reruns the full matrix.
External publication uses the separate
[Plugin ABI publication workflow](.github/workflows/plugin-abi-publish.yml).
It accepts an explicit `publish=true` manual dispatch and runs in the
`plugin-abi-release` environment, and the normal
[release workflow](.github/workflows/publish.yml) calls it as a reusable
workflow after the legacy `standard`/`all` images are verified. The automatic
call runs only when the lock is `ready`, its
`.abi.rulego_server.release_version` equals the resolved upstream version,
`should_build` is true, and the run is not staging-only. It passes
`promote_aliases=is_latest`, so publishing an older stable release writes its
immutable canonicals without moving `v<release>-<host>` backwards. Because the
same `should_build` gate stops the daily schedule once the legacy tags are
complete, a failed first ABI publication is recovered by rerunning the failed
run or dispatching this workflow with `publish=true`, not by the next scheduled
run. Native jobs stage their verified images with
commit-qualified tags; the release job creates two-platform indexes without
rebuilding, enforces first-writer immutable canonical tags, and verifies the
returned GHCR digests before producing its release record. Only after that record exists does it
move each host alias onto the canonical index this release verified, one host at a time, writing the
digest every alias held beforehand. A failed verification therefore leaves both tracks pointing at
the last build that passed, which is the property a moving name has to have to be safe to publish.

Two runtime casts were published before per-build canonical names existed, and the alias promotion
above took their only names. [The backfill workflow](.github/workflows/plugin-abi-backfill.yml)
gives them the names the naming function produces for the packaging revision each image carries in
its own config, from `plugin-abi-backfill.json`. A cast that labels a recipe other than the one
its name would carry is refused; the pre-split casts that carry no recipe label are exactly what
the plan names. It is dispatch-only and its `apply` input must be
`true` to write; a dispatch with `apply=false` re-derives everything and touches nothing. Every
target must be absent or already hold exactly those bytes, so a name that holds other content is a
refusal rather than a rewrite. The record it uploads is labelled with the moment it describes:
`post-write` answers what each name resolves to now, `pre-write` is what a run that died among its
writes leaves behind, and an entry nobody read back says `null` instead of `false` so a stopped run
cannot accuse a name it never checked. A plan is only accepted when the commit it cites
resolves in the checkout it is graded from, so this workflow and the offline suite both fetch the full
history: a shallow clone refuses instead of guessing. It exists as a workflow because a runner's
`GITHUB_TOKEN` is the only credential here that can push a container, and it stays because the write
is idempotent and its refusals are the point.

## Maintenance checks

The preparation script requires Bash, curl, jq, Python 3, tar, and GNU
coreutils. To validate both sets of upstream payloads without building or
starting containers:

```bash
scripts/fetch-release.sh v1.0.0 standard
scripts/fetch-release.sh v1.0.0 all
```

The compatibility record in `plugin-abi.lock` names the published SDK image that
the previous-generation probe loads. Two of its four values are registry digests
that nothing in this repository computes, so they are never typed by hand: a wrong
digit still validates, and only the probe would notice. Which revision that was is not
something anyone has to remember either: the newest published generation is a fact about
the registry, so the helper names it.

```bash
block=$(scripts/derive-compatibility-sdk.sh derive auto)
jq --argjson block "${block}" '.distribution.compatibility.previous_sdk = $block' \
  plugin-abi.lock >next.lock && mv next.lock plugin-abi.lock
scripts/plugin-abi.sh validate --candidate
```

There are two ways to name a published generation, and they ask different questions. A
revision asks "the release cut from this source": its identity comes from the lock at that
revision, never from a recomputation, because the identity function's domain has changed
once and today's function hashes an older contract into a name that generation was never
published under. An identity asks "the release published under this name", and it is the
only question still answerable about a generation whose commit this checkout cannot
read -- its identity then comes from what the published index annotates itself with.
`derive auto` uses the second form, because a commit is the one thing a published
generation is allowed to stop having; `previous` prints the same answer as an identity and
a commit, with `-` for a commit that is not here.

What has to agree is checked claim by claim: the tag resolves, the published index
annotates the identity it is named for, the two architectures are present and distinct,
and the image's own config names the commit it was built from. Against a revision that last
claim must name that revision; against an identity it must either name a commit that is
here and whose lock records the same identity, or be reported as unreadable. Refused
rather than guessed: no lock in the revision, a lock recording no identity or one that is
not a digest, a tag nobody published, a registry that would not answer, an index
annotating an identity other than the tag it answers to, an index missing an architecture,
an index that resolves both architectures to one digest, an image built from a commit that
is not the one asked about, a commit that is here but carries no contract or a different
one, one identity answering to two published names that hold different bytes -- the record
stores only the identity, so a second set of bytes is not one release -- or a tag that moved
between its two reads.

An unreachable commit is not on that list, and that is a measured fact rather than a
preference: of the published SDK tags in this repository, one cites a commit that no
remote ref carries, because it was cut from a dispatch ref that was later rewritten. A rule
that refuses an undated generation therefore makes the gate permanently red, and the only
way to green is to edit the gate by hand -- the transcription this helper exists to remove.
Publication order is the authority for which generation came last, because the registry
always records it; commit dates are the witness, read where they can be read. What stops
the answer is a contradiction between the two, not a missing witness: a listed tag that
does not resolve, a name holding an index that answers to another identity, a later
publication whose commit is older, a later publication built from a commit the earlier one
descends from, or a list of more than one generation where this checkout can date none --
which is how a shallow clone answers, and where trusting the order with no witness at all
would repeat the mistake that turned PR #21 red.

`scripts/derive-compatibility-sdk.sh check` reads the other way round: it takes the
record the lock already carries, compares it with the published index and both
architecture images, and then compares it with the published order: the record must name
the newest generation, not merely a published one. A rotation that was simply forgotten
leaves every digest in it correct, so the order is the only thing that can see it. The
pull-request job that probes canonical tags runs `check` on every change, so both a record
naming bytes nobody published and a record one generation behind fail before merge rather
than at the release that would have pulled them.

Rotating the record moves nothing that has been published. `.compatibility` is not part of
the manifest embedded in the images, so neither the lock identity nor the rendered manifest
digest changes when it rotates, and no canonical name is affected by it.

It does move the bytes of this file, which is what the golden identity vectors freeze in their
lock column, so a rotation turns `tests/plugin-abi-identity-vectors.sh` red until that column is
re-derived: `PLUGIN_ABI_DERIVE=1 bash tests/plugin-abi-identity-vectors.sh` prints what the shipped
lock now measures. Only the lock column may differ from the literals in the file. The identity
column and the embedded-document column are what those vectors exist to protect, and a rotation that
leaves the contract alone has to leave both of them exactly as they are -- if either moves, this is a
contract change to review, not a value to re-stamp.

The lock's own layout is the output of `jq .` and nothing else, which is why the recipe above can rewrite the
whole file with `jq` and still be a rotation: `tests/plugin-abi-lock.sh` refuses a lock whose bytes are not
what `jq .` prints. That assertion exists because the file arrived by hand, in four pieces, and each piece
kept the layout its author's tool produced -- 16 compact single-line objects among 98 lines of `jq` output,
with no check able to see the difference because every digest here is taken from `jq -S -c` bytes. Layout
carries no contract, so leaving it unowned cost a rotation's reviewability: the documented recipe moved 102
lines that had nothing to do with the record being rotated.

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

The publishing workflow builds and smoke-tests each architecture on its native
GitHub-hosted runner, pushes architecture images by digest, and then assembles
the version and moving tags as a two-platform OCI index
(`scripts/publish-index.sh`). That script binds each pushed digest to its
architecture and requires the two to differ before assembling the index, then
reports the tag it published so the run can be verified through it. It runs
`scripts/verify-build.sh` before publication and `scripts/verify-published.sh`
afterward. These CI-only gates perform native non-root HTTP smoke tests,
runtime-content checks, manifest completeness checks, executable digest
comparisons, and pair every architecture in the assembled index with its SLSA
provenance and SBOM attestations.

Transient API, registry, and download failures—including disconnected streams,
HTTP 429/5xx responses, and GitHub rate-limit responses—are retried with
bounded exponential backoff. Deterministic failures such as invalid versions,
ordinary 4xx responses, or checksum mismatches fail immediately.
