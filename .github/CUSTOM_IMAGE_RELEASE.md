# Custom Chatwoot image release controls

The Extended Horizons image path has three separate states:

1. pull requests build and scan locally on the GitHub runner;
2. a push to `integration/v4.16` or `develop`, or an explicit manual run on
   one of those two protected branches, publishes a uniquely tagged candidate
   and records its immutable digest;
3. a separate environment-gated workflow verifies and marks that exact digest
   as approved.

None of these workflows deploys Chatwoot.

## One-time repository controls

Before enabling promotion:

1. create a GitHub environment named `production-image-promotion`;
2. require Kevin as a reviewer and prevent self-review where the repository plan
   supports it;
3. restrict deployment branches to `integration/v4.16` and `develop`;
4. keep default workflow-token permissions read-only at repository level;
5. allow the two image workflows only the job-level permissions declared in
   their YAML;
6. protect `integration/v4.16` and `develop` against direct pushes;
7. require the candidate build and existing application test checks before
   merge.

If the environment does not have a required reviewer, promotion is not approved
for use.

## Candidate identity

Every published candidate has:

- a unique tag containing commit, workflow run ID, and run attempt;
- an OCI revision label containing the full Git commit;
- a registry digest;
- BuildKit SBOM and provenance;
- a GitHub artifact-attestation record;
- a Trivy JSON report;
- a JSON receipt naming the only valid deployment reference.

The deployment reference is always:

```text
ghcr.io/a-t-m-reef/chatwoot@sha256:<64 hexadecimal characters>
```

Tags are discovery labels. They are never deployment authority.

The vulnerability report is uploaded before the workflow enforces its current
gate. A candidate fails when Trivy finds a fixable critical vulnerability.
High-severity and unfixed findings remain in the evidence for explicit review.

## Promotion

Run `Promote custom Chatwoot candidate` with the digest, full commit, workflow
run ID, and run attempt copied from a green candidate receipt. The workflow first
performs a read-only verification job:

1. validates all four inputs;
2. requires the named workflow attempt to have completed successfully on
   `integration/v4.16` or `develop`;
3. downloads that attempt's candidate receipt and matches its repository,
   commit, digest, run ID, and run attempt;
4. verifies GitHub build provenance for the digest;
5. pulls and inspects the image without running it;
6. requires the OCI revision label to match the requested commit.

Only after those checks pass does the protected `production-image-promotion`
environment ask for approval. The mutation job then:

1. creates `approved-<full-commit>` only if that tag is absent;
2. refuses to overwrite the approved tag with another digest;
3. re-resolves the tag and requires exact digest equality;
4. uploads a one-year promotion receipt stating that no deployment occurred.

Promotion does not update Compose, pull on the VPS, migrate a database, restart a
service, or change traffic. Those are separate production actions requiring an
approved deployment package.

## Removal of the old behavior

The deployed fork workflow built on ordinary pushes to `develop` and
`feat/reply-all`, then overwrote `ghcr.io/a-t-m-reef/chatwoot:eh`. That workflow
is not carried onto the v4.16 line. The upstream Docker Hub publication jobs are
also repository-gated so this fork cannot accidentally publish official Chatwoot
images if upstream secrets are ever introduced.
