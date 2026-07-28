import { MESSAGE_STATUS, MESSAGE_TYPE } from 'shared/constants/messages';

/**
 * Determines the last non-activity message between store and API messages.
 * @param {Object} messageInStore - The last non-activity message from the store.
 * @param {Object} messageFromAPI - The last non-activity message from the API.
 * @returns {Object} The latest non-activity message.
 */
const getLastNonActivityMessage = (messageInStore, messageFromAPI) => {
  // If both API value and store value for last non activity message
  // are available, then return the latest one.
  if (messageInStore && messageFromAPI) {
    return messageInStore.created_at >= messageFromAPI.created_at
      ? messageInStore
      : messageFromAPI;
  }
  // Otherwise, return whichever is available
  return messageInStore || messageFromAPI;
};

/**
 * Filters out duplicate source messages from an array of messages.
 * @param {Array} messages - The array of messages to filter.
 * @returns {Array} An array of messages without duplicates.
 */
export const filterDuplicateSourceMessages = (messages = []) => {
  const messagesWithoutDuplicates = [];
  // We cannot use Map or any short hand method as it returns the last message with the duplicate ID
  // We should return the message with smaller id when there is a duplicate
  messages.forEach(m1 => {
    if (m1.source_id) {
      const index = messagesWithoutDuplicates.findIndex(
        m2 => m1.source_id === m2.source_id
      );

      if (index < 0) {
        messagesWithoutDuplicates.push(m1);
      }
    } else {
      messagesWithoutDuplicates.push(m1);
    }
  });
  return messagesWithoutDuplicates;
};

/**
 * Retrieves the last message from a conversation, prioritizing non-activity messages.
 * @param {Object} m - The conversation object containing messages.
 * @returns {Object} The last message of the conversation.
 */
export const getLastMessage = m => {
  const lastMessageIncludingActivity = m.messages[m.messages.length - 1];

  const nonActivityMessages = m.messages.filter(
    message => message.message_type !== 2
  );
  const lastNonActivityMessageInStore =
    nonActivityMessages[nonActivityMessages.length - 1];

  const lastNonActivityMessageFromAPI = m.last_non_activity_message;

  // If API value and store value for last non activity message
  // is empty, then return the last activity message
  if (!lastNonActivityMessageInStore && !lastNonActivityMessageFromAPI) {
    return lastMessageIncludingActivity;
  }

  return getLastNonActivityMessage(
    lastNonActivityMessageInStore,
    lastNonActivityMessageFromAPI
  );
};

const UNSUCCESSFUL_STATUSES = [MESSAGE_STATUS.FAILED, MESSAGE_STATUS.PROGRESS];

/**
 * Compares two message anchors. Both sides carry whole-second timestamps, so
 * collisions are ordinary and are broken on id rather than on the order the
 * messages happen to sit in the store array.
 * @param {Object} candidate - Message being considered.
 * @param {Object|null} current - Best message found so far.
 * @returns {boolean} Whether the candidate is the later message.
 */
const isNewerAnchor = (candidate, current) => {
  if (!current) return true;

  const candidateTime = Number(candidate.created_at);
  const currentTime = Number(current.created_at);
  if (candidateTime !== currentTime) return candidateTime > currentTime;

  return Number(candidate.id) > Number(current.id);
};

const isPublicIncoming = message =>
  !message.private && message.message_type === MESSAGE_TYPE.INCOMING;

const isSuccessfulReply = message =>
  !message.private &&
  message.message_type === MESSAGE_TYPE.OUTGOING &&
  !UNSUCCESSFUL_STATUSES.includes(message.status);

/**
 * Merges the server anchor with any newer store message that matches. The list
 * payload only carries the newest message, so the store is a tail rather than a
 * history and neither source alone is authoritative.
 * @param {Object} conversation - Conversation list payload.
 * @param {Object|null} seed - Anchor supplied by the server.
 * @param {Function} matches - Predicate selecting eligible store messages.
 * @returns {Object|null} The latest matching message.
 */
const latestAnchor = (conversation, seed, matches) =>
  (conversation.messages || []).reduce(
    (latest, message) =>
      matches(message) && isNewerAnchor(message, latest) ? message : latest,
    seed || null
  );

/**
 * Reports whether the newest public incoming message has a later successful
 * agent reply. Template and activity messages count on neither side, so a CSAT
 * survey or an auto-resolve notice cannot erase the marker, and a send that
 * failed or is still in flight cannot create it.
 * @param {Object} conversation - Conversation list payload.
 * @returns {boolean} Whether the agent has answered the latest inbound message.
 */
export const isConversationReplied = conversation => {
  const reply = latestAnchor(
    conversation,
    conversation.last_agent_reply_message,
    isSuccessfulReply
  );
  if (!reply) return false;

  const incoming = latestAnchor(
    conversation,
    conversation.last_public_incoming_message,
    isPublicIncoming
  );

  return isNewerAnchor(reply, incoming);
};

/**
 * Filters messages that have been read by the agent.
 * @param {Array} messages - The array of messages to filter.
 * @param {number} agentLastSeenAt - The timestamp of when the agent last saw the messages.
 * @returns {Array} An array of read messages.
 */
export const getReadMessages = (messages, agentLastSeenAt) => {
  return messages.filter(
    message => message.created_at * 1000 <= agentLastSeenAt * 1000
  );
};

/**
 * Filters messages that have not been read by the agent.
 * @param {Array} messages - The array of messages to filter.
 * @param {number} agentLastSeenAt - The timestamp of when the agent last saw the messages.
 * @returns {Array} An array of unread messages.
 */
export const getUnreadMessages = (messages, agentLastSeenAt) => {
  return messages.filter(
    message => message.created_at * 1000 > agentLastSeenAt * 1000
  );
};
