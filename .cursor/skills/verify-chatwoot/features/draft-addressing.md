# Draft addressing during delivery updates

WOOT-29 preserves unsent To, Cc, Bcc and From edits while an earlier email's delivery state updates.

## Sub-features

- draft-delivery-update: an earlier delivery update preserves all four addressing fields.
- draft-send-update: updates after Send preserve the next reply's edited recipients.

## How to get to it (user POV)

- Open a Dummy Email conversation from All Conversations; use the reply header's recipients, Add bcc and available From selector.
- Keep the draft unsent while an earlier outgoing message changes delivery state.

## Driving it with browser-harness

Preconditions: Doctor passes and an admitted synthetic fixture supplies editable To/Cc/Bcc/From plus a controllable real delivery-status event. The current baseline lacks that event fixture. Stop here and report this recipe blocked; the generator pilot does not run it.

- **Locate.** Inspect cdp('Accessibility.getFullAXTree')['nodes'] and visible reply-header controls. Use Add bcc and accessible field names. Fail if a required field is unavailable.
- **Edit.** Type distinct .test addresses through visible controls. Capture their rendered values with capture_screenshot() and focused DOM value reads. Type an unsent body without Send.
- **Observe event.** Deliver the admitted earlier message through the approved local transport and observe its visible delivery-status change. Vue/store setters or fabricated websocket events cannot satisfy this claim.
- **Compare.** Read the same four fields and draft body. All must equal the pre-event values. An unchanged screenshot without an observed event is inconclusive.
- **Scope.** Exercise delivery-update and post-send-update cases independently and report each event's evidence.

## Gotchas

- Mapped, unexecuted. Event-fixture admission remains an explicit dependency.
- Source grounding: app/javascript/dashboard/components/widgets/conversation/ReplyBox.vue and specs/ReplyBox.spec.js, email recipients across message updates cases.
- Unit tests alone cannot establish browser race or transport behavior.
- Preserve operator drafts; clean only an admitted test-owned draft using its agreed fixture procedure.
