# Email forward

An agent forwards one email of a conversation to new recipients with a covering note. The recipients get the original body and attachments; the customer is not addressed, and a reply to the forward opens a new conversation.

## Sub-features

- forward-gating: the message context menu offers Forward on incoming and outgoing email messages, not on a private note or a failed message.
- forward-validation: an empty or invalid To keeps the dialog open with an error; nothing is sent or stored.
- forward-send: To, Cc and a note send one forward; the thread shows it with its To, Cc and Fwd: subject and the forwarded block expanded.
- forward-deliver: Mailpit receives Fwd: <subject>, exactly the chosen To/Cc, the inbox address as From, no In-Reply-To or References, the note, the forwarded header block, the original HTML, and the original attachments byte for byte.
- forward-persist: one public outgoing message with forwarded_message_id, to_emails and the Fwd: subject, attached by reusing the source blobs.
- forward-retry: a failed forward retried from the UI is delivered again to its own recipients, never the customer.
- forward-reply: a reply whose In-Reply-To is the forward's Message-ID opens a new conversation with the replier as contact.
- forward-sent-copy: re-rendering the forward the way Sent sync archives it matches the delivered mail.
- forward-composer: after forwarding, the reply composer is not addressed to any forward recipient.
- forward-scope: a forward naming a source message from another conversation is refused (422) and sends nothing.

## How to get to it (user POV)

- Any email conversation → right-click a message → Forward → fill To, optional Cc and a note → Forward.
- The pilot drives the seeded forward conversation (contact Synthetic Vendor, subject Synthetic invoice 42).

## Driving it with browser-harness

Preconditions: Doctor passes on the candidate with the site running; exactly one dummy app tab in the chosen profile (Profile 14 unless --profile names another). The fixture is created on first run by forward_fixture.rb seed (additive, idempotent; no reset).

- **Open.** Navigate the adopted tab to the forward conversation; sign in with the synthetic credentials only if the login form shows. Wait until the source renders as an email (its "Subject: Synthetic invoice 42" header): messages are plain bubbles until the inbox loads, and email-only actions appear only after that.
- **Menu.** Right-click the bubble header (24px, 14px in from its top-left), read the `.menu-container .menu` labels, then close by clicking the far side of the same bubble: the menu closes on focus loss and opens at the click point.
- **Dialog.** Click Forward in the menu; the dialog is `dialog[open]` with `data-testid` forward-email-to, forward-email-cc and a textarea note. Clear a field by select-all plus Backspace before typing; fill_input's own clear leaves a character behind.
- **Send.** Click the dialog's Forward button; require the dialog to close and the thread bubble carrying the marker to show "Forwarded message".
- **Retry.** verify.py marks the third forward failed; the retry mode clicks the message's `i-lucide-refresh-ccw` button and requires "Failed to send" to clear.
- **Run.** `python3 -B .cursor/skills/verify-chatwoot/scripts/verify.py forward --expected-sha <candidate> --target-id "$CHATWOOT_TARGET_ID"` runs F1 to F10 and writes receipt.json with one pass/fail per check.

## Gotchas

- The forward run needs the site already running and leaves it running; it does not restart or log out. Run the pilot separately for login and the ordinary reply (R1).
- IMAP is disabled in the dummy, so the reply scenario feeds a synthetic mail to Imap::ImapMailbox in-process. Live IMAP transport is unverified here.
- Synthetic forwards, the replier's new conversations and Mailpit captures are retained and marked. A broad reset needs separate approval.
- Each run adds three forwards and one retry to the forward conversation; markers keep runs apart.
