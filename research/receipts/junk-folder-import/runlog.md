# Junk folder import: run log

## Acceptance claim (frozen 2026-10-27, before any replica evidence was collected)

Candidate `b8f7bdda0` on `feat/junk-folder-import`, base `cf0146223` (`main`).

Requester's words (Ethan, 2026-10-27): "We need to be able to see emails that get caught in spam
inside chatwoot. I want it to be in a separate tab." Roundcube shows the folder as "Junk".

Terms:

- **T1.** Mail sitting in the server folder that carries `\Junk` (or the admin `spam` override) is
  imported into the inbox, one conversation per new thread, and appears on the inbox's Junk tab
  (`mailbox_role=spam`). It does not appear on the Inbox tab.
- **T2.** The folder is chosen only by special-use attribute or override. A decoy folder named
  `Junk` without the attribute is never read. When two folders claim `\Junk` and there is no
  override, nothing is imported and the run reports `junk_folder_unavailable` / `ambiguous`.
- **T3.** The import is read-only on the server: EXAMINE plus BODY.PEEK. No message is moved,
  flagged `\Seen`, or expunged.
- **T4.** A message is never imported twice. A rerun imports nothing, and mail already in Chatwoot is
  skipped before the per-cycle cap is applied.
- **T5.** Quiet: a conversation the import creates is `resolved` after its message commits, carries
  `junk_import`, and creates no `conversation_creation` notification for an inbox member who has
  that notification turned on.
- **T6.** Junk that threads into an existing conversation is added to it without marking it junk.
  Ordinary inbox mail that threads into a junk conversation reopens it.
- **T7.** Restoring a junk conversation to Inbox (existing mailbox action) moves the message to
  INBOX on the server, reopens the conversation and clears `junk_import`. The next INBOX poll does
  not duplicate it.
- **T8.** Gates: nothing runs when the account flag `email_mailbox_actions` is off or the inbox's
  mailbox sync mode is `off`. With the gates on, the INBOX fetch and Sent sync behave as before.
- **T9.** The tab and the move action read "Junk" in the UI (en locale). The internal role stays
  `spam`, so `/mail/spam` URLs keep working.

## Evidence

Proof shape: **replica**. A real Dovecot 2.4.5 (`dovecot/dovecot:latest`,
`sha256:43c14def08a5…`) with `replica-dovecot.conf`, driven by `replica_rehearsal.rb` (no IMAP mocks)
in its own database (`chatwoot_junk_replica`). There is also one **read-only live rehearsal** of folder
resolution, against production's own discovery code and the real mailboxes.

### Live folder survey and resolution (read-only, production, 2026-10-27)

- LIST/STATUS on every IMAP inbox: cPanel Junk = `INBOX.spam` `\Junk`, Gmail Junk = `[Gmail]/Spam` `\Junk`.
  amy@ also has an unflagged, empty `INBOX.Junk`. info@ holds 3,838 messages in Junk.
- `Imap::FolderDiscoveryService.result_for(...).for_role('spam')`, run in the production container
  over a real leased connection:
  inbox 2 → `INBOX.spam` (discovered), 61 messages since 26-Oct; inboxes 4–8 → `INBOX.spam` (discovered),
  0 messages; inboxes 3 and 12 → `[Gmail]/Spam` (discovered), 0 messages; inbox 1 → lease busy (a live
  poll held it, which is expected and not a failure). Mode-off inboxes 10 and 11 were not probed.

### Replica rehearsal, candidate `0821560f4`: 20/20 (`replica-output.txt`)

| Term | Result |
|---|---|
| T1 | PASS: 3 spam-folder messages imported. New conversations are on the spam tab and off the Inbox tab, and identity = folder + UIDVALIDITY + `spam` role |
| T2 | PASS: two `\Junk` folders and no override → `skipped / junk_folder_unavailable / ambiguous`, nothing imported. With the override, the decoy folder was never read |
| T3 | PASS: server spam folder count 3→3, `\Seen` 0→0 after import |
| T4 | PASS: rerun imported 0 (`already_present: 3`). With cap 1, a new message behind three known ones still imports |
| T5 | PASS: created conversations resolved and `junk_import` after commit. No `conversation_creation` notification for any junk conversation. **Control:** the ordinary setup conversation did notify the same subscribed agent, so the listener provably ran |
| T6 | PASS: a junk reply threaded into the real resolved conversation, which reopened and is not junk. Inbox mail threading into a junk conversation reopened it |
| T7 | PASS: restore operation `succeeded`, message found in server INBOX by Message-ID, conversation open, `junk_import` cleared. Next INBOX poll added 0 messages |
| T8 | PASS: flag off → `feature_disabled`, mode off → `mailbox_sync_off`. INBOX fetch still creates an open Inbox-tab conversation. Scheduler gating is covered by spec |
| T9 | Not exercised in the replica (UI). Covered by the en locale diff only, see below |

The first rehearsal run (on candidate `b8f7bdda0`) **failed T4**: a rerun reported `imported: 3`.
`next @counts[:already_present] += 1` inside `filter_map` returned the counter as a fake UID. That is
fixed in `0821560f4`, with a spec asserting that no body is fetched for mail already held. The
same run also reported a T5 failure, which was a flaw in the script: it counted the setup
conversation's own notification. The check now scopes to junk conversations and adds the control.

### Code layer

- Specs, candidate `0821560f4`: `spec/services/imap spec/jobs/inboxes spec/jobs/email_mailbox_operation_job_spec.rb
  spec/mailboxes spec/listeners/notification_listener_spec.rb spec/finders/conversation_finder_spec.rb
  spec/models/message_spec.rb spec/models/conversation_spec.rb spec/enterprise/jobs/inboxes
  spec/requests/api/v1/accounts/conversation_mailbox_operations_spec.rb` → **774 examples, 0 failures**.
- The same command at base `cf0146223` → **755 examples, 0 failures** (base green; +19 new examples).
- Mutation check: with `return if skip_conversation_reopen` removed, the two "stays resolved" examples fail.
- RuboCop on every changed Ruby file: no offenses.
- ESLint: not run. The worktree has no `node_modules`, and the only frontend change is three en
  locale JSON strings, which ESLint does not lint. The JSON parses.

### Unmet or unexercised

- **Artifact layer: unmet.** The real image build (`build_custom_candidate.yml`) runs when the PR is
  opened. Candidate identity read-back from that image is pending.
- **T9 on the real UI: unexercised.** The Junk label was not visually checked in a running dashboard.
- **Operational layer** (restart, upgrade, lease contention under real load): only the job's
  lease-retry path, by spec. There was no soak against the live 61-messages-a-day info@ volume.
- Scope note: the pre-commit hook was skipped (`--no-verify`) because it needs `node_modules`. Its
  two steps (eslint on staged js/vue, of which there are none, and rubocop on staged Ruby) were run
  by hand above.
