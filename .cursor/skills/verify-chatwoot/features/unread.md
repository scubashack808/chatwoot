# Preserve newer unread state

WOOT-31 prevents an older read timer from clearing a newer unread mark or incoming message.

## Sub-features

- unread-new-mark: a newer Mark as unread action survives the earlier pending read timer.
- unread-new-message: a new synthetic incoming message remains unread when an older timer fires.

## How to get to it (user POV)

- Open a conversation from All Conversations, then use its card menu's Mark as unread.
- Receive a new message while a prior read operation is pending.

## Driving it with browser-harness

Preconditions: Doctor passes and an admitted timing fixture demonstrates an older pending read timer plus a newer event. Incoming transport is absent from this baseline. Stop and report these unmet prerequisites. No application-internal state setter may manufacture a pass.

- **Order.** Open the test card; retain the action timestamp and observed pending-read timing evidence.
- **Mark.** Inspect the exact card menu with cdp('Accessibility.getFullAXTree')['nodes']; choose visible Mark as unread and capture the unread indicator/timestamp.
- **Observe.** Allow the older timer's measured deadline to pass. Capture the unread indicator and read-only persisted state. The newer mark must remain unread.
- **Incoming.** Repeat using real synthetic incoming transport under the separately admitted fixture. Record message identity, event order, timer completion and resulting unread state.
- **Negative control.** Demonstrate on the affected baseline that the ordering triggers the stale-timer condition. Arbitrary sleeps cannot establish this race.

## Gotchas

- Mapped, unexecuted. The mail pilot provides no timing or inbound-transport proof.
- Reloading or reopening after Mark as unread can legitimately mark it read and invalidate observation.
- Browser throttling/load affect timing; record event order rather than assuming a delay.
- Ground the admitted fixture in the source's current read-timer mechanism and WOOT-31 acceptance. Never invent a timeout or force Vue/store state.
