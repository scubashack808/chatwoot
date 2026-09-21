// A read is applied to the store four seconds after it is acknowledged, so it
// must not clear unread state that became newer while its timer was waiting.
// Writes that affect unread state stamp the conversation here, and a deferred
// read only applies if the stamp still matches the one it captured.
//
// This is kept outside the conversation objects on purpose: the store replaces
// or drops those objects on list refresh, filter change and reconnect, which
// would reset the stamp and make a pending read compare against a baseline it
// never captured.
const sequenceByConversationId = new Map();

export const getUnreadWriteSequence = conversationId =>
  sequenceByConversationId.get(conversationId) ?? 0;

export const recordUnreadWrite = conversationId => {
  sequenceByConversationId.set(
    conversationId,
    getUnreadWriteSequence(conversationId) + 1
  );
};
