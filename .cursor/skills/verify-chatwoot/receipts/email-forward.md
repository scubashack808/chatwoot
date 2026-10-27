# Email forward (WOOT-12)

## Intent and boundaries

Request (Ethan, 2026-10-27): "We need to implement chatwoot forwarding capabilities." Ruling the same day: build it; a reply to a forward opens a new conversation. WOOT-12's own acceptance asks that a forward from production conversation 3992 deliver the Coupa HTML body and attachments with a typed note.

Base: cf01462236 (main). Parent PR: 7524effc3 (verify-chatwoot accepts this Mac's renamed hostname and can run in a chosen governed profile). Branch: feat/woot-12-email-forward. This record is reconstructed: the claim below was written after the runs it reports, not frozen before them.

Out of scope: deployment, the live conversation 3992 check, the iOS app, live IMAP transport, Send Transcript, and every other mapped feature.

## Acceptance terms

1. Forward is offered on incoming and outgoing email messages in Email inboxes, not on a private note or a failed message; an empty or invalid To (including ",,") is refused and nothing is sent.
2. Recipients get one email: Fwd: subject (never doubled), the note, the forwarded header block, the original HTML and the original attachments byte for byte, from the conversation's usual address, with the customer not addressed; a forwarded agent reply is attributed to the inbox, never the agent's login.
3. The forward starts a new thread: no In-Reply-To or References, Reply-To is the inbox's own address, and a reply to it opens a new conversation on the IMAP, ActionMailbox and Sent-import paths.
4. The source is looked up inside the conversation only (received or sent, not private, failed or deleted); a foreign source is refused and sends nothing.
5. A retried forward keeps its recipients and body.
6. The Sent-sync re-render matches the delivered mail.
7. Ordinary replies are unchanged, and a forward neither shapes the next reply's addressing nor counts as a reply to the customer (waiting state, first reply, first-reply eligibility of the next real reply).
8. (WOOT-12, in the requester's terms) Conversation 3992 forwards the Coupa body and attachments. **Unmet here**: it needs a deploy, which this record does not cover.

## Results

- **Forward journey, run forward-20261027T223648303231Z, candidate b650111ef, Brave Profile 15:** 48 of 48 checks pass (terms 1 to 7 as exercised end to end). The same 48 checks also passed in Profile 14 on f869b9d12 (run forward-20261027T221146756544Z); application code is identical between the two heads. Retained summary with every check and the helper hashes: [email-forward-results.json](email-forward-results.json). This run's thread screenshot was inspected (forwarded agent reply shown as `Dummy Agent <support@chatwoot-dummy.test>`, no To row in the reply composer, the failed forward's retry control), as were the dialog and validation screenshots of earlier passing runs.
- **Discriminating evidence:**
  - F10 failed on df8b49f88, before the reply-addressing fix, with the reply composer addressed `To: forward-to-4@chatwoot-dummy.test` (run forward-20261027T213731786087Z).
  - The five specs added for the adversarial-review fixes (first reply after a forward, agent-reply attribution, failed source, forward Reply-To, Sent-import refusal) fail on 4c62a81a6 and pass on f869b9d12.
  - The two ActionMailbox strategy specs fail on main and pass on the branch.
- **Ordinary reply (term 7), existing pilot:** passes on the final head b650111ef in Profile 15 (run 20261027T223932873182Z) with both Doctor negative controls, cleanup and restoration; the captured reply kept `Re: Dummy booking question`, In-Reply-To, References and the customer as recipient. It had also passed on 459ae26c0 in Profile 14. In Profile 14 on f869b9d12, three attempts (20261027T221259170460Z, 20261027T221422063730Z, 20261027T221502086353Z) stopped at login, before any send, because a Zoho Vault save prompt took the typed keystrokes; that is why the harness gained --profile.
- **Specs:** the wider set (builder, mailer, IMAP mailbox, messages controller, mailbox and IMAP services, message model) fails only on the 21 cases that fail identically on main in this dummy test environment (17 message model, 2 Sent sync, 2 reply mailer). This is a differential result, not a green trunk.
- **Frontend:** eslint clean; vitest for the conversation store, components-next/message and the reply widgets pass.
- **Harness:** 47 of 47 helper tests pass.
- **Independent review:** a fresh agent with only the diff and the claim found two falsifications (forward Reply-To kept the conversation's reply+uuid address; a forward blocked the next reply's first-reply credit) and four should-fix items; all are fixed in d6f754898 and covered above. Not fixed, accepted: attachments with only an external URL are not carried, and files over the mailer's 20 MB total arrive as links, as for any reply.

Application code is unchanged since f869b9d12; the later commits add the --profile flag to the harness and this receipt.

Reproduce from this verification checkout with the dummy running on the candidate:

    python3 -B .cursor/skills/verify-chatwoot/scripts/verify.py forward \
      --expected-sha <candidate> --target-id "$CHATWOOT_TARGET_ID"
