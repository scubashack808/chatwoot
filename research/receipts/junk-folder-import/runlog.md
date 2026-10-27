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

(appended below as it is collected)
