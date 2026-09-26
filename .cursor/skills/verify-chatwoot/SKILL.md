---
name: verify-chatwoot
description: Verify Chatwoot's web UI on the approved native synthetic dummy copy. Use for the WOOT-43 pilot, login and locally captured email-reply proof, or diagnosing pilot readiness. Includes a regression map; broader regression, native-phone and release acceptance remain separate.
---

# Verify Chatwoot

## Launch

1. Read this file and [the feature index](features/README.md). This is the repository-owned output of pstack's create-verification-skill workflow, pinned upstream at 0.15.2. The generator itself is unchanged.
2. Work from ~/Cursor/chatwoot-scubashack808 on chore/woot-38-verification. The separate runtime is ~/Cursor/chatwoot-dummy, candidate d76b96565762a2b491fa444e9870ee216d9f63ca, on MacBook-Air.local. Never substitute the other Mac, VPS or production. This skill requires the existing provisioned native runtime; it does not install one.
3. Read the runtime's .codex/dummy/README.md, ~/.claude/skills/browser-rules/SKILL.md, the installed ~/.claude/skills/browser-harness/SKILL.md and ~/.config/browser-harness/runtime-contract.json. Preserve the single governed Brave and CC01 (Profile 14). No browser installation/restart, alternate driver, personal profile or runtime override.
4. Inspect current state:

    cd ~/Cursor/chatwoot-scubashack808
    python3 -B ../chatwoot-dummy/.codex/dummy/manage.py status

The runtime supplies Rails/Puma, Vite, Sidekiq, dedicated Redis and Mailpit. Shared PostgreSQL supplies only chatwoot_dummy_dev/test. Shared PostgreSQL/Redis must stay running. Ports: Rails 3001, Vite 3038, dedicated Redis 6380, SMTP 1025, Mailpit 8025; all on 127.0.0.1.

For an explicitly requested manual start or stop, use the corresponding command, never both as a readiness check:

    python3 -B ../chatwoot-dummy/.codex/dummy/manage.py start
    python3 -B ../chatwoot-dummy/.codex/dummy/manage.py stop

The pilot command below owns launch and cleanup. If already running, --restart-existing explicitly permits a brief dummy-only interruption and restores its prior running state afterward. Do not use it during another operator's work. A nonblocking advisory lock serializes cooperating verification runs. This is one local-user runtime, without hostile-code confinement or disposable per-run databases.

**Done when:** the provisioned runtime exists on the authorized host, its state is known, and the requested test permits synthetic mutations and any restart. Never seed, reset or install dependencies automatically.

## Doctor

Run the read-only check before driving and whenever a result looks wrong:

    python3 -B .cursor/skills/verify-chatwoot/scripts/verify.py doctor

Exit 0 requires the exact candidate, clean tracked runtime source, no untracked application source, matching Git repository, private local credentials, correct loopback configuration, the owned supervisor and all five services, and listener PID/user/working-directory/command identity. Listener ancestry must lead to the service PID reported by the verified supervisor socket; the worker must contain the expected Sidekiq leader. Source/configuration timestamps must predate the running backend/Vite. It checks expected HTTP identity, local mail API, a unique synthetic incoming fixture and the synthetic password. Fixture queries use an explicit read-only PostgreSQL transaction. No login request, reset or data write is used by Doctor; ordinary service access/boot logging can still occur.

Exit 2 is a refusal. Read check/error; never substitute another service or edit the expected SHA to hide failure. A changed candidate needs a newly approved candidate/fixture contract. Credentials come from the dummy .env and are never printed.

The pilot executes two negative controls: Doctor against a genuinely stopped dummy stack, and Doctor against an all-zero expected candidate while the stack is healthy. Both must refuse at the expected stage.

**Done when:** Doctor returns ok: true, or the exact failing precondition is reported without browser mutation.

## Drive

Read [login](features/login.md) and [email reply](features/email-reply.md). Discover tabs before input:

    BH_TELEMETRY=0 ~/.local/bin/browser-harness <<'PY'
    for tab in discover_tabs(include_chrome=False):
        if tab['url'].startswith('http://127.0.0.1:3001/'):
            print(tab)
    release_caller()
    PY

Choose the exact synthetic task tab by target ID, full URL, title and Profile 14; never choose the first URL match. Set CHATWOOT_TARGET_ID to that observed ID. Ambiguity is a stop. If no authorized tab exists, use the installed browser-opening procedure first; never allocate a replacement to evade a mismatch. Permitted entries: login, the synthetic dashboard and fixture conversation. Doctor returns current account/display IDs; reset can change the display ID.

Run the complete pilot from the verification checkout:

    python3 -B .cursor/skills/verify-chatwoot/scripts/verify.py pilot \
      --target-id "$CHATWOOT_TARGET_ID" --restart-existing

Omit --restart-existing when already stopped. The script verifies the supported process-scoped BH_TELEMETRY=0 opt-out before browser work, assigns a unique supported BU_CALLER identity for release, and rechecks metadata before adoption. It refuses other dummy app tabs sharing the login. Before service interruption, navigation or logout, a read-only preflight rejects stored drafts under draftMessages, current editor/attachment state and unfamiliar visible input values. It repeats that guard before the actual journey. It reloads only that document, logs out through the UI if needed, proves wrong-password rejection, signs in with synthetic credentials, selects All Conversations and Synthetic Customer, types one unique reply in the visible ProseMirror editor, and clicks Send. DOM access inspects/selects visible controls; input uses the governed driver's clicks/typing. No Vue/store setters, token injection or message-creation API shortcut.

An existing unsent body or unfamiliar addressing draft is a stop. Before interruption or reload, recipient values are checked by field: To must be the synthetic customer, From the synthetic sender, Cc empty or the known customer prefill, and Bcc empty. The fixture login email is allowed only in its login-page field. A composer whose email controls cannot be inspected is refused, including modes that hide pending addressing. The known synthetic customer duplicated in Cc is explicitly cleared through the visible field before composing; the mail recipe records this fixture setup. Reconcile a failed/unknown send through the saved marker, conversation, captured email and database receipt before a new run. Never blindly replay Send.

**Done when:** the exact reply is rendered with a cleared composer, Mailpit receives exact body/From/To with no extra recipients, and a separate read-only database view reports exactly one persisted public outgoing sent message.

## Evidence

Every attempt gets tmp/verify-chatwoot/<UTC run ID>/ under this verification checkout, separate from dummy reset/storage paths. The private, Git-ignored directory survives successful and failed cleanup.

- receipt.json: candidate, outcome, errors, initial state, teardown/restoration and limits.
- skill-hashes.json: exact local skill/helper bytes. No commit/publication is implied.
- doctor-*.json, initial-doctor.json, restored-doctor.json: identity, fixtures and negative controls.
- actions.jsonl: timestamped UI actions/results, without credential values.
- 01-login through 05-sent: screenshots, text and accessible role/name snapshots; password values excluded.
- captured-email.json and persisted-message.json: independent delivery/persistence evidence tied to the unique marker.
- lifecycle.log, browser-preflight.log, browser-journey.log, browser-release.log and failure screenshots: unsuccessful attempts remain visible.
- browser-privacy.json and browser-timeout.json (when applicable): opt-out proof and unknown-action warnings.

Inspect screenshots before reporting visual success. Report entry points individually. Seeded incoming content plus outgoing SMTP capture proves this pilot; it does not prove inbound IMAP, live customer mail, WOOT-29/30/31, phones, production parity, release or rollback. Remaining paths have explicit map status.

**Done when:** the real action, resulting UI state, delivery side effect, candidate identity and cleanup survival have evidence. A screenshot or HTTP 200 alone is insufficient.

## Cleanup

A preflight refusal leaves the original services untouched. Once lifecycle work begins, the pilot's finally block stops only the worktree-owned supervisor, including owned partial startups, verifies its ports close and original shared PostgreSQL/Redis listeners remain. If initially running, it starts and rechecks that same dummy afterward. The browser recipe releases its caller even when evidence writing fails; the parent independently releases the same unique caller on timeout. Partial restoration is stopped if it fails readiness. SIGINT/SIGTERM are handled through cleanup; a hard process or machine kill still requires manual reconciliation. No real tabs or Brave are closed by the helper.

Synthetic proof messages and captured mail are deliberately retained with unique markers. This pilot makes no pristine-per-run data claim and performs no broad reset. Obtain explicit authorization before manage.py reset --yes, which discards all dummy test records and invalidates login.

After interruption, inspect receipt.json, browser-result.json, the exact supervisor and mailbox first. Never launch another pilot while the first owns the lock. If cleanup/restoration is unconfirmed, reconcile the exact owned processes; never kill by name, stop shared services or erase evidence.

**Done when:** run-owned services are stopped, prior availability is restored when required, proof survives and retained synthetic mutations are disclosed.

## Helpers

All helpers are repository-owned and executable. They add app-specific wiring around existing pstack/browser/runtime tools.

- verify.py doctor: read-only readiness, invocation above.
- verify.py pilot: full owned lifecycle and UI proof, invocation above.
- mail_flow.py: executed by browser-harness on stdin from pilot, using its per-run VERIFY_CHATWOOT_CONFIG. Requires the pilot lease and Doctor receipt; never invoke independently.
- inspect_fixture.rb: read-only Rails fixture/auth/persistence inspection. Standalone invocation:

    python3 -B ../chatwoot-dummy/.codex/dummy/manage.py exec -- \
      bundle _2.5.16_ exec rails runner \
      "$PWD/.cursor/skills/verify-chatwoot/scripts/inspect_fixture.rb"

Focused helper checks:

    python3 -B .cursor/skills/verify-chatwoot/tests/test_verify.py

Canonical source: .cursor/skills/verify-chatwoot/, matching upstream pstack. The repository's .claude/skills/verify-chatwoot alias points to the same directory. Local alias readability is testable; automatic Factory discovery and fresh Factory-builder/reviewer execution remain separate acceptance work. No global installation.

Use the installed /maintain-verification-skill during an explicitly authorized maintenance pass as the app changes. No schedule is created. The operator approved this provisioned native route in place of the retired VM execution lane. This skill leaves canonical planning records unchanged; broader task acceptance is separate from this local pilot.
