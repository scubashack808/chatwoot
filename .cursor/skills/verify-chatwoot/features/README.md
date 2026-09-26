# Chatwoot verification map

Read this index before driving. Canonical skill: [../SKILL.md](../SKILL.md).

## Baseline preconditions

- Approved native copy on MacBook-Air.local, candidate d76b96565762a2b491fa444e9870ee216d9f63ca.
- Account Chatwoot Dummy, agent agent@chatwoot-dummy.test, inbox Dummy Email, contact Synthetic Customer (customer@chatwoot-dummy.test).
- Unique incoming fixture: Synthetic booking question. Can you confirm the test reservation?
- Doctor discovers IDs. Reset preserves the display-ID sequence; never assume display ID 1.
- Loopback Mailpit captures outgoing SMTP. Incoming mail is seeded; IMAP is disabled.
- One pilot holds the advisory lease. Operator work and noncooperating callers must stay out while it runs.

## Driving conventions

Use the governed browser-harness, exact target adoption and CC01. Follow installed browser rules. Prefer role/name or stable source-grounded selectors. Observe before input and verify each action. Login/mail automation pairs actions with results, screenshots and independent delivery/persistence checks.

## Proof and skip reporting

The pilot exercises login and the seeded-email reply entry point. Regression recipes are mapped from source and WOOT-38; timing/multi-conversation fixtures remain unimplemented. Stop at their unmet preconditions rather than manufacturing state. Native iOS WOOT-1 remains deferred and outside this web map.

A receipt proves only its recorded candidate/helper hashes. Later changes need new proof. Read actual pass/fail from run receipts; a map entry itself is never a result.

## Features

- [Login](login.md): rejection, sign-in, logout. Implemented pilot entry point.
- [Email reply](email-reply.md): seeded conversation, public reply, SMTP capture, stored state. Implemented pilot; inbound transport unverified.
- [Draft addressing](draft-addressing.md): WOOT-29, preserve unsent fields across delivery updates. Mapped, unexecuted.
- [Conversation snooze](snooze.md): WOOT-30, snooze B while A is selected. Mapped, unexecuted.
- [Unread state](unread.md): WOOT-31, stale timer versus newer unread events. Mapped, unexecuted.
