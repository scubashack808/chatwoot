# Native verification skill: publication receipt

## Acceptance claim and authorization

This record was written on 2026-09-26 before the PR-candidate checks. The implementation and the 2026-09-24 local pilot already existed; their history below is **reconstructed**, not a claim frozen before implementation. The operator explicitly requested: **“Publish a PR.”** That authorizes branch publication and opening a PR, not approval, merge, deployment or a reset.

The PR establishes a repository-owned, manually readable `verify-chatwoot` skill with a same-source discovery alias and executable readiness/UI-proof helpers for the **already provisioned, serial native synthetic runtime**. On that admitted runtime, it must reject unsafe readiness/draft conditions; prove rejected credentials followed by UI login, one visible composer reply, exact locally captured outbound mail and exact persisted public sent state; and retain evidence while stopping only owned services and restoring prior availability.

One reason to merge: provide the first reusable, app-specific local verification entry point. One rollback: revert this skill, its alias, ignore exceptions and receipts. No production application files, schemas, accounts, mail configuration, packaging or deployment behavior are changed by the PR. The skill can interrupt its explicitly admitted local dummy stack and send synthetic mail, so ownership, credential handling and draft preservation are consequential parts of this same outcome.

## Candidate and scope

- PR base/application runtime: `d76b96565762a2b491fa444e9870ee216d9f63ca`.
- PR head: recorded in the PR body after commit; it cannot be self-embedded in its own tree.
- Standard: PR Delivery Standard v1.4.0, pin `6ed4974`, SHA-256 `59161cb6c235d1f3ff6436de2351aadc429add53d861b20ebb9aab453c792479`.
- No stacked PR dependency. The provisioned runtime manager and browser driver are required external code dependencies.
- New helper checks do not exist at the base. No product-regression or green-trunk claim is made.
- The diff touches only agent instructions, Python/Ruby verification helpers, focused tests, a symlink, ignore rules and this evidence. Repository search found no affected-projects selector applicable to these files. There is no new Chatwoot build artifact; the interpreted skill/helpers are the artifact under test. Full Rails/Vite production build, product suites, signing and release checks are outside this claim.

## Proof shape and prerequisites

Proof shape: **local native synthetic replica**, limited to this pilot. It reuses the pinned application source, the existing Rails/Puma/Vite/Sidekiq stack, a separate dummy database/role, dedicated Redis, local Mailpit and the governed browser driver. The inbound message is a seeded fixture; outgoing delivery reaches local SMTP only. This is not a production-parity, hostile-code-isolation or pristine-database claim.

This PR does **not** provision a fresh clone. The approved host, adjacent `~/Cursor/chatwoot-dummy` worktree, private `.codex/dummy/manage.py` environment manager, private credentials and installed browser tools already exist. These local assets are deliberately not published. The skill refuses a different host, candidate, repository, service identity or configuration. A reviewer without this setup can inspect the durable proof; running the pilot requires separately approved provisioning. The focused DOM test also reuses JSDOM from that worktree’s pinned frontend install.

## Replay on the admitted runtime

1. Read `.cursor/skills/verify-chatwoot/SKILL.md` and its linked feature map. Read the installed browser rules and runtime contract before browser work.
2. Run `python3 -B .cursor/skills/verify-chatwoot/tests/test_verify.py`. Expected: 23 focused tests, including a real-template DOM attachment check and refusal-before-navigation cases. The tests use mocks or a detached DOM, not real service mutations.
3. Run `python3 -B .cursor/skills/verify-chatwoot/scripts/verify.py doctor`. Expected: `ok: true`, exact application candidate and synthetic fixture.
4. Discover the authorized synthetic tab through the governed driver with process-scoped `BH_TELEMETRY=0`; use its observed target ID. Never select a fuzzy match or another caller’s tab.
5. Run `python3 -B .cursor/skills/verify-chatwoot/scripts/verify.py pilot --target-id "$CHATWOOT_TARGET_ID" --restart-existing` only when a dummy-only restart is authorized and no other operator is using it. The pilot covers UI login/reply, local delivery, persistence, stopped-stack and wrong-candidate controls, cleanup and restoration. It retains one synthetic outgoing message and email.
6. End on the standalone refusal: `python3 -B .cursor/skills/verify-chatwoot/scripts/verify.py doctor --expected-sha 0000000000000000000000000000000000000000`. Expected: exit 2, candidate mismatch, no browser action.

Do not alter a draft, reset the fixture, disable a gate or replay an unknown Send to make a check pass. A hard process/machine kill still requires manual reconciliation.

## Durable evidence and honesty boundaries

`prepublication/` contains selected, sanitized evidence from the successful 2026-09-24 run `20260924T232811720954Z`: helper test output, startup/readiness refusals, exact mail and message state, outcome/cleanup receipt, source hashes, review closure and a final UI screenshot. These files predate the PR commit. Their original helper bytes are identified by hashes; the local raw originals and earlier unsuccessful attempts were preserved.

Public copies replace the local home path, remove browser target/profile ownership metadata and omit private configuration, personal documents, Plane payloads and raw browser logs. A manifest records source and published hashes. Sanitization does not turn old evidence into exact-commit evidence. The PR body records the **fresh checks on its exact head**, their actual results and any unmet terms; the retained historical bundle is supporting context.

Prior independent review found telemetry, draft, timeout/release, partial-restoration, process-identity and substring-proof defects. The corrections were checked in separate reviews. The final attachment review ran all 23 tests and confirmed that a pasted-file-only preview is rejected before navigation/logout. That review did not assess the parent-run live pilot. A new independent review covers the published candidate and PR claim.

## Explicitly outside acceptance

- Inbound IMAP or real customer mail.
- The three mapped draft-addressing, snooze and unread regression journeys.
- Automatic Factory discovery or fresh Factory builder/reviewer execution.
- Native phone clients, production readiness, release, deployment or merged-trunk proof.
- Portable provisioning, alternate browser/profile/host support and arbitrary-agent isolation.

Human review/approval and an explicit merge authorization remain separate. Merging this PR authorizes no live-system action.
