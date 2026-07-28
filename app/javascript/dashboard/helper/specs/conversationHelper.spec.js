import {
  filterDuplicateSourceMessages,
  getLastMessage,
  getReadMessages,
  getUnreadMessages,
  isConversationReplied,
} from '../conversationHelper';
import {
  conversationData,
  lastMessageData,
  readMessagesData,
  unReadMessagesData,
} from './fixtures/conversationFixtures';

describe('conversationHelper', () => {
  describe('#filterDuplicateSourceMessages', () => {
    it('returns messages without duplicate source_id and all messages without source_id', () => {
      const input = [
        { source_id: null, id: 1 },
        { source_id: '', id: 2 },
        { id: 3 },
        { source_id: 'wa_1', id: 4 },
        { source_id: 'wa_1', id: 5 },
        { source_id: 'wa_1', id: 6 },
        { source_id: 'wa_2', id: 7 },
        { source_id: 'wa_2', id: 8 },
        { source_id: 'wa_3', id: 9 },
      ];
      const expected = [
        { source_id: null, id: 1 },
        { source_id: '', id: 2 },
        { id: 3 },
        { source_id: 'wa_1', id: 4 },
        { source_id: 'wa_2', id: 7 },
        { source_id: 'wa_3', id: 9 },
      ];
      expect(filterDuplicateSourceMessages(input)).toEqual(expected);
    });
  });

  describe('#readMessages', () => {
    it('should return read messages if conversation is passed', () => {
      expect(
        getReadMessages(
          conversationData.messages,
          conversationData.agent_last_seen_at
        )
      ).toEqual(readMessagesData);
    });
  });

  describe('#unReadMessages', () => {
    it('should return unread messages if conversation is passed', () => {
      expect(
        getUnreadMessages(
          conversationData.messages,
          conversationData.agent_last_seen_at
        )
      ).toEqual(unReadMessagesData);
    });
  });

  describe('#lastMessage', () => {
    it("should return last activity message if both api and store doesn't have other messages", () => {
      const testConversation = {
        messages: [conversationData.messages[0]],
        last_non_activity_message: null,
      };
      expect(getLastMessage(testConversation)).toEqual(
        testConversation.messages[0]
      );
    });

    it('should return message from store if store has latest message', () => {
      const testConversation = {
        messages: [],
        last_non_activity_message: lastMessageData,
      };
      expect(getLastMessage(testConversation)).toEqual(lastMessageData);
    });

    it('should return last non activity message from store if api value is empty', () => {
      const testConversation = {
        messages: [conversationData.messages[0], conversationData.messages[1]],
        last_non_activity_message: null,
      };
      expect(getLastMessage(testConversation)).toEqual(
        testConversation.messages[1]
      );
    });

    it("should return last non activity message from store if store doesn't have any messages", () => {
      const testConversation = {
        messages: [conversationData.messages[1], conversationData.messages[2]],
        last_non_activity_message: conversationData.messages[0],
      };
      expect(getLastMessage(testConversation)).toEqual(
        testConversation.messages[1]
      );
    });
  });

  describe('#isConversationReplied', () => {
    // Replied means the newest public incoming message has a later successful
    // agent reply. Templates, activity events and private notes never count on
    // either side, and a send that failed or is still in flight is not a reply.
    const incoming = (overrides = {}) => ({
      id: 10,
      message_type: 0,
      created_at: 100,
      private: false,
      status: 'sent',
      ...overrides,
    });
    const outgoing = (overrides = {}) => ({
      id: 20,
      message_type: 1,
      created_at: 200,
      private: false,
      status: 'sent',
      ...overrides,
    });
    const anchorOf = message => ({
      id: message.id,
      created_at: message.created_at,
    });
    const conversation = ({ messages = [], reply, lastIncoming }) => ({
      messages,
      last_agent_reply_message: reply ? anchorOf(reply) : null,
      last_public_incoming_message: lastIncoming
        ? anchorOf(lastIncoming)
        : null,
    });

    it('is true when a successful reply is newer than the newest incoming message', () => {
      expect(
        isConversationReplied(
          conversation({ lastIncoming: incoming(), reply: outgoing() })
        )
      ).toBe(true);
    });

    it('is false when the newest incoming message has no later reply', () => {
      expect(
        isConversationReplied(
          conversation({
            lastIncoming: incoming({ created_at: 300 }),
            reply: outgoing(),
          })
        )
      ).toBe(false);
    });

    it('is false when a newer incoming message arrives in the store after the reply', () => {
      expect(
        isConversationReplied(
          conversation({
            messages: [incoming({ id: 30, created_at: 300 })],
            lastIncoming: incoming(),
            reply: outgoing(),
          })
        )
      ).toBe(false);
    });

    it('does not count an optimistic send that failed', () => {
      expect(
        isConversationReplied(
          conversation({
            messages: [
              outgoing({ id: 'temp-uuid', created_at: 300, status: 'failed' }),
            ],
            lastIncoming: incoming({ created_at: 250 }),
          })
        )
      ).toBe(false);
    });

    it('does not count an optimistic send that is still in progress', () => {
      expect(
        isConversationReplied(
          conversation({
            messages: [
              outgoing({
                id: 'temp-uuid',
                created_at: 300,
                status: 'progress',
              }),
            ],
            lastIncoming: incoming({ created_at: 250 }),
          })
        )
      ).toBe(false);
    });

    it('keeps the marker when a CSAT survey template lands after the reply', () => {
      expect(
        isConversationReplied(
          conversation({
            messages: [
              {
                id: 40,
                message_type: 3,
                content_type: 'input_csat',
                created_at: 400,
                private: false,
                status: 'sent',
              },
            ],
            lastIncoming: incoming(),
            reply: outgoing(),
          })
        )
      ).toBe(true);
    });

    it('keeps the marker when an auto resolve template lands after the reply', () => {
      expect(
        isConversationReplied(
          conversation({
            messages: [
              {
                id: 41,
                message_type: 3,
                created_at: 400,
                private: false,
                status: 'sent',
              },
            ],
            lastIncoming: incoming(),
            reply: outgoing(),
          })
        )
      ).toBe(true);
    });

    it('ignores a newer private note on either side', () => {
      expect(
        isConversationReplied(
          conversation({
            messages: [
              incoming({ id: 50, created_at: 500, private: true }),
              outgoing({ id: 51, created_at: 501, private: true }),
            ],
            lastIncoming: incoming(),
            reply: outgoing(),
          })
        )
      ).toBe(true);
    });

    it('ignores a newer activity message', () => {
      expect(
        isConversationReplied(
          conversation({
            messages: [{ id: 60, message_type: 2, created_at: 600 }],
            lastIncoming: incoming(),
            reply: outgoing(),
          })
        )
      ).toBe(true);
    });

    it('breaks an exact-second tie on message id when the reply is newer', () => {
      expect(
        isConversationReplied(
          conversation({
            messages: [
              outgoing({ id: 71, created_at: 700 }),
              incoming({ id: 70, created_at: 700 }),
            ],
          })
        )
      ).toBe(true);
    });

    it('breaks an exact-second tie on message id when the incoming is newer', () => {
      expect(
        isConversationReplied(
          conversation({
            messages: [
              incoming({ id: 71, created_at: 700 }),
              outgoing({ id: 70, created_at: 700 }),
            ],
          })
        )
      ).toBe(false);
    });

    it('is true when the agent started the thread and no incoming message exists', () => {
      expect(isConversationReplied(conversation({ reply: outgoing() }))).toBe(
        true
      );
    });

    it('is false when the conversation carries no messages or anchors', () => {
      expect(isConversationReplied({})).toBe(false);
    });
  });
});
