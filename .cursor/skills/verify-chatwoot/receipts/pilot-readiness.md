# Pilot document-readiness repair

## Intent and boundaries

User request: “Make the pilot reliable.” This follow-up is limited to the existing native login/reply pilot. It does not implement the remaining WOOT-38 regression map, fresh provisioning, Factory consumption, database resets, phone testing, publication, deployment, or broader ticket closure.

Base: a7d806e4a447db087d3ba4f03427ba7b82a9d2db. Application fixture: d76b96565762a2b491fa444e9870ee216d9f63ca on the already provisioned native dummy. Branch: fix/woot-38-pilot-readiness.

This claim is written before this repair and its qualification. Earlier evidence is historical: two post-merge runs (20260926T174535937275Z and 20260926T174853777885Z) refused at document loading, preserved shared services and restored the dummy. The installed browser driver defaults wait_for_load to 15 seconds; the pilot already allows 90 seconds for application-state readiness but does not pass that budget to document loading.

## Acceptance terms

1. Forward the existing bounded readiness budget to the real document-load helper. Preserve the document-complete gate and all subsequent rendered-state, draft, recipient, mail and persistence assertions. No automatic navigation or Send retry.
2. Retain document-load outcome, elapsed time and budget in each attempt’s existing private action evidence, including timeout outcomes.
3. Discriminating tests must fail against the old call site: a document arriving after the driver default but within the pilot budget proceeds; exhausted or invalid readiness results stop before application input and still release the caller.
4. Existing helper safety, timeout-release and lifecycle tests remain passing. New checks use the real main-flow branch rather than testing a disconnected duplicate.
5. Run the unchanged complete CLI lifecycle at least twice with the repaired helper bytes. Each successful run must prove rejected credentials, visible login/reply, exact captured SMTP and one persisted public sent message, plus negative Doctor controls, cleanup, shared-service preservation, evidence survival and restoration of the prior running state.
6. Retain any unsuccessful attempts and inspect state before another mutation. A fresh independent reviewer must challenge the final diff and proof. Report live versus mocked failure coverage explicitly.

## Architecture and reuse

Canonical blueprint rows were read without modification: Glassworks (bp4), Shared Inbox (component 22), Mail Client (component 23), and the linked thin-patch decision 609. Current repository identity and the approved native route come from WOOT-38’s recorded owner rulings; canonical deployment descriptions retain older fork names. This changes only repository-owned verification code and evidence. It reuses the installed driver’s public timeout parameter and the existing native launcher, rather than changing the browser installation, application, transport, fixtures or gate semantics.

The installed maintenance workflow was consulted for edit boundaries and live re-proof. This is a targeted pilot repair, not a full-map maintenance pass. The remaining mapped features keep their existing unexecuted status.

## Results

The source delta forwards WAIT_SECONDS=90 to wait_for_load, requires the documented native True result, and logs the load budget/outcome/monotonic elapsed time in a finally block. The existing 300-second whole-browser ceiling remains unchanged. All later draft, UI, exact-recipient, SMTP, persistence and cleanup gates remain in place; no action retry was added.

- Regression discrimination: the expanded suite ran against the unchanged old call site first. It ran 33 tests and failed 5 assertions/subtests for the missing timeout forwarding, missing failure timing and unsupported truthy results. The existing 29 tests remained passing.
- Fixed checks: all 33 tests pass under Python 3.14 and the installed driver’s Python 3.12.13. Ruby helper lint/syntax, Python parsing, skill validation, the same-source alias, private ignore boundaries and git diff whitespace checks pass.
- Installed-driver contract check: the actual installed wait_for_load and initial-document predicate were compiled with a deterministic clock and document responses. A document ready at 45 seconds fails its 15-second default and passes timeout=90. Readiness after 91 seconds and a persistent initial blank document both refuse under the 90-second budget. This is simulated document/clock coverage, not a live delayed-network claim. Installed driver SHA-256: 6112da06a24bdae1e6e8d1e6c22085c5fefb475803444e16d0763f3e0c73b698.
- Fresh unchanged-base pilot 20260927T005235593031Z passed. The original failure is intermittent; this record does not claim it failed every time or that today’s live runs needed more than 15 seconds.
- Repaired native run 20260927T005659242236Z passed; document load 9.645619291812181 seconds; persisted synthetic outgoing message 9.
- Repaired native run 20260927T005916494086Z passed; document load 8.858333124779165 seconds; persisted synthetic outgoing message 10.

Both repaired runs used identical executable helpers and operating instructions. Their full manifests as recorded at run time are in [the retained summary](pilot-readiness-results.json). This result document and summary were completed afterward, so the earlier manifest entry for this document is historical rather than a claim about its final reporting bytes. Each proved wrong-password rejection, visible login and reply, exact body/From/To with empty Cc/Bcc in local SMTP capture, exactly one persisted public outgoing sent message, stopped-stack and wrong-candidate refusal, caller release, owned shutdown, unchanged shared-service identities, evidence survival and restoration of the prior running state. Rejection and reply screenshots from both runs were inspected. The immediate reply screenshot can precede mail delivery; the later mail and database receipts establish delivery and sent state separately.

Reproduce from this verification checkout, following the skill’s Doctor, discovery and draft-preflight instructions:

    python3 -B .cursor/skills/verify-chatwoot/tests/test_verify.py
    python3 -B .cursor/skills/verify-chatwoot/scripts/verify.py pilot --target-id "$CHATWOOT_TARGET_ID" --restart-existing

The negative load-result, driver-error and parent timeout/release cases are deterministic tests. No live stuck-load fault was injected in this repair. Two successful repaired native runs are repeatability evidence, not a reliability guarantee under every possible host load.

Private logs/screenshots/captures remain under tmp/verify-chatwoot/<run-id>; the portable result summary above excludes credentials and browser metadata. All three new synthetic proof messages (one baseline, two repaired) and captured emails are retained. There was no database reset, application/runtime/driver change, dependency update, global configuration change or production action.

Independent review and any final reporting-snapshot confirmation are recorded on WOOT-38 at closeout. This receipt alone makes no review-approval claim. Changes remain local and uncommitted on fix/woot-38-pilot-readiness. No publication or merge is authorized or claimed. WOOT-38’s broader acceptance remains open.
