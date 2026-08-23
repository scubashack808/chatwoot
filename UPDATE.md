# Chatwoot v4.17.0 local candidate

Run ID: `chatwoot-v4.17.0-20260823`

Status: composed; candidate-bound verification pending

## Frozen identities

- Official target tag: `v4.17.0`
- Official target commit: `b34f5b71a4d7f41fa87cf2b32260e2c887817e54`
- Official target tree: `4f7dfb547095bddd030bf15d4379342594def3eb`
- Common base and prior official release: `70e284a044f00326725f65f703162745371075ec` (`v4.16.2`)
- Exact deployed private source to carry: `c36e17ff9e98cef0e9af87fe021a65a396ee8470`
- Exact deployed private tree: `9083e9a96816b3389946fbd7ee364a89a3d6666e`
- Isolated branch: `codex/update-v4.17.0-candidate-20260823`
- Isolated worktree: `/Users/kevinleib/CursorProjects/chatwoot/worktrees/update-v4.17.0-20260823`

The official release was refreshed read-only immediately before the worktree was created. GitHub still reports `v4.17.0` as latest, and the remote annotated tag still peels to the frozen target commit. The private refs were also refreshed read-only: the deployed mailbox-gate branch still points to exact `c36e17ff9`, its phone-display parent still points to `1d73da868`, and `integration/v4.16` still points to `37f1a241b`.

## Authority boundary

Authorized in this run: local worktree and branch creation, local files and commits, semantic reconciliation, complete local testing, an unpublished local image, an isolated synthetic replica, Browser Harness interaction only with that replica, and local evidence.

Forbidden in this run: push; remote ref creation or movement; PR creation or update; merge; registry publication; release; install; restart or deployment; production migration; production-data copy; production browser action; cleanup of another lane's worktrees, artifacts, containers, images, volumes, or caches; and public-upstream mutation.

The terminal outcome is an approval-ready local candidate and morning receipt. It is not an installed software update.

## Source disposition before composition

| Source | Disposition | Reason |
|---|---|---|
| Official `v4.17.0` at `b34f5b71a` | Accept as new base | This is the frozen stable target. |
| Exact live source `c36e17ff9` | Carry in full | Production intentionally runs this exact source. Dropping any of it would regress accepted live behavior. |
| `integration/v4.16` at `37f1a241b` | Inherited through `c36e17ff9` | It is an ancestor of the exact live source, so it is not replayed independently. |
| Phone-display recovery `1d73da868` | Inherited through `c36e17ff9` | It is an accepted live delta and direct ancestor of the mailbox-gate stack. |
| Mailbox publication-gate stack through `c36e17ff9` | Inherited through exact live source | This exact stack is deployed, green, and required for the current mailbox contract. |
| Row 12 suggestion work | Exclude | It was not accepted and is absent from the exact live source. |
| Sidebar-curation, email-state-baseline, dirty RC scratch, and all other local branches/worktrees | Exclude | They are unrelated or separately owned work. |
| Private image-publication workflow files already in the live source | Carry as source only | They are part of the maintained source, but no remote ref will move and no workflow or publication will be triggered tonight. |

## Composition topology

The candidate starts at exact official `v4.17.0` and merges exact live `c36e17ff9` locally. This retains a deliberate two-parent ancestry bridge and makes the candidate a descendant of both the official target and the deployed private source. The merge remains uncommitted until every textual conflict is resolved and every one of the 38 upstream/private changed-path overlaps is reviewed semantically, including clean automerges.

Composition produced nine textual conflicts. All are resolved, no unmerged paths or conflict markers remain, and the staged tree passes `git diff --check`. The custom candidate workflow and its documentation now target the prospective `integration/v4.17` delivery line instead of the prior `integration/v4.16` line. This is only a local source adaptation; no remote branch exists or moved in this run.

## Semantic overlap disposition

Every path changed by both exact live source and official v4.17 was reviewed as behavior, including paths Git merged without a textual conflict.

| Area | Paths | Disposition |
|---|---|---|
| Message retry | `messages_controller.rb` | Keep v4.17's row-locked atomic retry claim and source-ID reset. Preserve only the selected owned `from_email` while clearing prior failure state and other stale delivery attributes. |
| Conversation visibility and counts | `conversation_finder.rb` and CE/Enterprise finder specs | Keep the live mailbox-role relation, ordering, pagination, and Enterprise SLA compatibility. Keep v4.17's participating-conversation access restriction and agent-bot assigned/unassigned count semantics. |
| Inbox API and settings | `inboxes.js`, `featureFlags.js`, `ConfigurationPage.vue`, `busEvents.js` | Preserve live aliases, folder discovery, sync configuration, and mailbox events alongside v4.17 WhatsApp configuration, delayed automations, and MFA events. |
| Conversation list and navigation | `ChatList.vue`, `ConversationHeader.vue`, `contextMenu/Index.vue`, and three locale JSON files | Preserve mailbox role navigation, operation state, hard-delete recovery, and aliases. Keep v4.17 error-finalization, layout, search-package, macro, and locale changes. |
| Reply composer | `ReplyBox.vue` | Preserve From selection, Reply All, alias ownership, recipient sanitization, and mailbox routing. Keep v4.17 macro selection, bot handoff, Instagram constraints, messaging-window rules, and effective draft-mode behavior. |
| Reconnect and real-time events | `ReconnectService.js`, `actionCable.js`, and their specs | Preserve full mailbox-role refresh and selected-row operation recovery. Keep v4.17 route-specific error tolerance, voice-call events, and cache behavior. |
| Conversation state store | conversation actions, state, mutations, and specs | Preserve server-derived mailbox operations, terminal-state monotonicity, selected-row polling, and hard-delete error payloads. Keep v4.17 filtered-fetch error propagation and assignee-type behavior. |
| Contact display | `ContactInfoRow.vue` | Preserve the exact live phone-display recovery while retaining v4.17's full-width inline editing fix. |
| IMAP fan-out and locking | both fetch jobs and `base_fetch_email_service.rb` | Keep the live owner-token lease and single `Imap::Session`; do not stack v4.17's generic mutex or perform a second raw mailbox selection. Keep v4.17 structured start, skip, OAuth, connection, completion, and failure logging around the live fetch/reconcile/sent-sync fan-out. |
| Outbound mail rendering | `conversation_reply_mailer.rb` and specs | Use v4.17's `current_message` as the one message identity. Preserve alias-aware From/Reply-To, exact-message To/Cc/Bcc and subject rendering for sent synchronization, and v4.17 sender-name construction. |
| Models, policies, serializers, routes, and events | `message.rb`, `inbox_policy.rb`, both JSON partials, `routes.rb`, `types.rb` | Preserve IMAP identities, mailbox permissions, reply anchors, mailbox payloads, and operation routes/events. Keep v4.17 template fields, reindex guards, WhatsApp permissions, SLA gating, and upstream routes/events. |
| Locale and schema conflicts | `config/locales/en.yml`, `db/schema.rb` | Keep both the v4.17 resolved-conversation copy and live hard-delete copy. Bind schema to v4.17's `2026_08_14_000000` version while retaining all live private columns, tables, indexes, and earlier migrations. Migration timestamps remain unique. |
| Feature flag allocation | `config/features.yml`, `spec/models/account_spec.rb` | Production already persists `email_mailbox_actions` at bit 5 (`32`), while v4.17 independently assigned that bit to `delayed_automations`. Keep mailbox actions at `32`, assign delayed automations the next free bit `64`, and assert both exact values so persisted account state cannot be reinterpreted. |
| API request specs | conversations and message retry specs | Preserve live reply anchors, mailbox publication constraints, operation query bounds, bot account isolation, custom-attribute behavior, and selected-From retry identity. Keep v4.17's atomic retry and new API expectations. |

The feature-bit collision was a clean-merge production hazard: accepting the official order would have silently treated every production mailbox-action flag as delayed automations and removed the mailbox UI. The explicit allocation above preserves stored production meaning.

## Production facts carried as constraints

- Rails and Sidekiq currently run version 4.16.2 from exact source `c36e17ff9` and image `sha256:c6136b87b45a24b5c4b4ce856ae6cd2fc7a395ccc8965de3e89d44de33d0cd95`.
- All currently published mailbox behavior, phone display behavior, alias routing, sent synchronization, quoted-reply behavior, RingCentral retry behavior, and accepted conversation behavior must survive.
- The production source is ahead of the older merged integration branch and must not be replaced by that older branch.
- The current dead scheduled-job history and RingCentral bridge restart count are live-state warnings. They are not candidate defects, but they remain separate blockers to any later cutover.

## Verification contract

1. Bind the composed source, tree, lockfiles, migrations, and build inputs.
2. Review all private/upstream overlaps and all actual merge conflicts at behavior level.
3. Run focused tests for changed private and shared seams, then the complete 16-shard backend matrix, complete frontend suite, RuboCop, ESLint, security comparison, and official-target baseline comparison for any unexplained failures.
4. Review Enterprise overlays and inspect the final diff for secrets, production endpoints, generated debris, debug code, and excluded work.
5. Build an unpublished exact-source image using the repository's container toolchain.
6. Prove migrations, restart behavior, web/worker health, email and mailbox behavior, contact phone display, RingCentral failure/retry behavior, and ordinary conversation behavior on an egress-blocked synthetic replica.
7. Use Browser Harness only after positively identifying the isolated replica target.
8. Refresh the official target and private carried refs once at the end, selectively invalidate affected evidence, and emit separate product, package, runtime, delivery, and production-readiness verdicts.

## Evidence ledger

| Gate | State | Identity or note |
|---|---|---|
| Target and authority freeze | pass | Exact refs and boundary above |
| Source composition | pass | Nine textual conflicts resolved; no unmerged paths or markers; staged diff check clean |
| Overlap review | pass | All 38 changed-path intersections reviewed semantically; feature-bit collision repaired |
| Focused checks | pending | Candidate-bound |
| Full source gates | pending | Complete backend/frontend/lint/security |
| Exact local image | pending | Must remain unpublished |
| Synthetic replica | pending | Must be egress-blocked and production-isolated |
| Rendered UI | pending | Browser Harness against replica only |
| Final refresh and terminal receipt | pending | One bounded refresh after evidence |

## Stop conditions

Stop without improvising if a live behavior cannot be reconciled safely, a migration would discard required state, a check needs production data or credentials, isolation from production cannot be proven, the frozen target moves, or the next action would cross a forbidden remote or live boundary.
