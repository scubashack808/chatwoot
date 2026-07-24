# Custom Chatwoot candidate images

This repository builds immutable candidates. It does not promote or deploy
them.

## What runs

- A pull request targeting `integration/v4.16` or `develop` builds and scans an
  `amd64` image locally. The job has no package write permission.
- A merge or other push to either named branch builds and pushes a uniquely
  tagged candidate.
- No manual-dispatch path exists. This lets the integration branch exercise the
  workflow before the final cutover to the default branch.

Each published candidate records:

- the full Git commit in its tag and OCI revision label;
- its immutable registry digest;
- a BuildKit SBOM;
- a GitHub build-provenance attestation;
- a Trivy report;
- a JSON receipt naming the exact digest reference.

The only valid deployment reference is:

```text
ghcr.io/<hosting repository>@sha256:<64 hexadecimal characters>
```

The image namespace follows whichever repository hosts the build (the interim
`scubashack808/chatwoot` today, the canonical repository after migration), so
the pipeline needs no edits when the repo moves. Only the upstream
`chatwoot/chatwoot` repository is excluded from building candidates.

The unique candidate tag is for discovery only. Production must never deploy a
tag.

## Scan gate semantics

The vulnerability gate fails only on CRITICAL findings that are NOT present in
the matching upstream `chatwoot/chatwoot` release image (resolved from
`config/app.yml`). A thin-patch fork cannot fix upstream's dependency tree, so
upstream-inherited findings are recorded in the evidence artifact (candidate
scan plus baseline scan) without blocking, while anything our patches introduce
fails the build. First candidate run (2026-07-24) recorded 36 inherited
criticals, all in upstream's JavaScript build dependencies.

## Approval boundary

Building a candidate is not approval to deploy it. Kevin's later deployment
approval names one exact digest together with the tested migration and rollback
package. There is no separate mutable "approved" tag and no workflow in this PR
that contacts the VPS, changes Compose, migrates, restarts, or changes traffic.

## Repository controls required before adoption

The workflow does not supply repository governance. Before using this as the
merge path, keep default workflow-token permissions read-only, protect
`integration/v4.16` and `develop` against direct pushes, and require the
candidate build plus application tests before merge.

The old fork workflow that overwrites
`ghcr.io/a-t-m-reef/chatwoot:eh` is not carried forward. Upstream Docker Hub
publisher jobs are also repository-gated so the fork cannot publish official
Chatwoot images.
