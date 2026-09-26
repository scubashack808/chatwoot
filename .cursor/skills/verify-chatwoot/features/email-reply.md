# Email reply

An agent opens a seeded conversation and sends a public reply visible in both the conversation and local captured mailbox.

## Sub-features

- email-open: All Conversations opens Synthetic Customer and displays seeded text.
- email-draft: the reply editor contains the exact new marker before Send.
- email-send: Send clears the editor and renders the outgoing reply.
- email-deliver: Mailpit receives exact body, support@chatwoot-dummy.test From, customer@chatwoot-dummy.test To and no Cc/Bcc.
- email-persist: a separate read-only view reports exactly one public outgoing sent message.

## How to get to it (user POV)

- All Conversations → Synthetic Customer in Dummy Email: pilot entry point.
- Dummy Email under Channels also exposes it; that alternative is explicitly unverified until exercised separately.

## Driving it with browser-harness

Preconditions: Login and Doctor pass, the seeded conversation is open and the composer has no draft. IDs come from Doctor.

- **Open.** Click a[title="All Conversations"], then h4.conversation--user with exact text Synthetic Customer. Require the Doctor-provided URL, seeded incoming text and div.ProseMirror[contenteditable="true"].
- **Recipients.** Inspect visible To/From/Cc/Bcc before typing. Preserve unexpected drafts. The known synthetic customer duplicated in Cc may be explicitly removed using the visible input and Backspace, followed by blur; capture the chosen empty Cc/Bcc scope. Any other prefilled recipient is a stop.
- **Draft.** Click the observed editor; type the per-run Verify Chatwoot marker using fill_input. Require exact rendered equality. Capture 04-draft before Send.
- **Send.** Click the visible Send (⌘ + ↵) button. Require empty editor and the exact marker in the conversation. Capture 05-sent.
- **Delivery.** Read Mailpit /api/v1/messages and then /api/v1/message/{ID} for newly observed IDs. Require exact body and sender/recipient equality. These reads never replace UI Send.
- **Persistence.** The runner calls inspect_fixture.rb in a read-only transaction. persisted-message.json must contain exactly one matching public outgoing sent message.
- **Run.** python3 -B .cursor/skills/verify-chatwoot/scripts/verify.py pilot --target-id "$CHATWOOT_TARGET_ID" --restart-existing runs this recipe and both Doctor negative controls with teardown.

## Gotchas

- Never overwrite a draft or automatically resend after timeout; reconcile the marker first.
- Incoming content was seeded; IMAP transport remains unverified.
- Require a unique marker and new Mailpit ID so old messages cannot pass.
- A qualification attempt found customer@chatwoot-dummy.test in both To and Cc. Its failed evidence is retained. Recipient setup is now explicit through the UI; no application fix or root-cause claim is implied.
- The synthetic reply and capture are retained. A broad reset needs separate approval.
- Private Note cannot pass: public persisted state plus SMTP capture are mandatory.
