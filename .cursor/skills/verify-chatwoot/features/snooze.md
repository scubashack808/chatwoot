# Snooze the intended conversation

WOOT-30 makes a list-card snooze affect that card while another conversation stays selected.

## Sub-features

- snooze-other-card: with A selected, snoozing B changes B and leaves A unchanged.
- snooze-selected: the selected conversation's status control affects only that conversation.

## How to get to it (user POV)

- In All Conversations, select A, open B's card context menu and choose Snooze.
- The selected conversation's status dropdown also offers snooze; it needs a separate proof.

## Driving it with browser-harness

Preconditions: Doctor passes and an admitted two-conversation synthetic fixture names distinct A/B display IDs and initial statuses. The current baseline has one conversation. Stop here and report the unmet precondition; the pilot never silently adds fixtures.

- **Select A.** Use h4.conversation--user in the list; require A's active route. Capture the selected pane.
- **B menu.** Inspect B's current card and accessibility tree. Use the installed driver's context-menu interaction on that exact card. Require A's route remains selected.
- **Snooze B.** Choose the visible Snooze menu and a displayed duration. Record the exact choice, action and B's resulting status/due time.
- **Compare.** Read both conversations through a separate read-only state view and reopen through the UI. B must be snoozed and A unchanged. Selection movement alone proves nothing.
- **Selected entry.** Independently exercise the selected conversation's status dropdown when that entry point is authorized.

## Gotchas

- Mapped, unexecuted. A one-conversation test cannot establish wrong-target behavior.
- Restore only the admitted fixture's recorded statuses during cleanup.
- Grounding: ConversationCard.vue, conversation/contextMenu, conversation.json Snooze labels and WOOT-30.
- Coordinates come from the current B card/menu observation, never the selected pane by assumption.
