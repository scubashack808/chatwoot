import { actions } from '../../conversation/actions';
import { mutations } from '../../conversation/mutations';
import getUuid from '../../../../helpers/uuid';
import { API } from 'widget/helpers/axios';

vi.mock('../../../../helpers/uuid');
vi.mock('widget/helpers/axios');

const commit = vi.fn();
const dispatch = vi.fn();

describe('#actions', () => {
  describe('#createConversation', () => {
    it('sends correct mutations', async () => {
      API.post.mockResolvedValue({
        data: {
          contact: { name: 'contact-name' },
          messages: [{ id: 1, content: 'This is a test message' }],
        },
      });

      let windowSpy = vi.spyOn(window, 'window', 'get');
      windowSpy.mockImplementation(() => ({
        WOOT_WIDGET: {
          $root: {
            $i18n: {
              locale: 'el',
            },
          },
        },
        location: {
          search: '?param=1',
        },
      }));
      await actions.createConversation(
        { commit },
        { contact: {}, message: 'This is a test message' }
      );
      expect(commit.mock.calls).toEqual([
        ['setConversationUIFlag', { isCreating: true }],
        [
          'pushMessageToConversation',
          { id: 1, content: 'This is a test message' },
        ],
        ['setConversationUIFlag', { isCreating: false }],
      ]);
      windowSpy.mockRestore();
    });
  });

  describe('#addOrUpdateMessage', () => {
    it('sends correct actions for non-deleted message', () => {
      actions.addOrUpdateMessage(
        { commit },
        {
          id: 1,
          content: 'Hey',
          content_attributes: {},
        }
      );
      expect(commit).toBeCalledWith('pushMessageToConversation', {
        id: 1,
        content: 'Hey',
        content_attributes: {},
      });
    });
    it('sends correct actions for non-deleted message', () => {
      actions.addOrUpdateMessage(
        { commit },
        {
          id: 1,
          content: 'Hey',
          content_attributes: { deleted: true },
        }
      );
      expect(commit).toBeCalledWith('deleteMessage', 1);
    });

    it('plays audio when agent sends a message', () => {
      actions.addOrUpdateMessage({ commit }, { id: 1, message_type: 1 });
      expect(commit).toBeCalledWith('pushMessageToConversation', {
        id: 1,
        message_type: 1,
      });
    });
  });

  describe('#toggleAgentTyping', () => {
    it('sends correct mutations', () => {
      actions.toggleAgentTyping({ commit }, { status: true });
      expect(commit).toBeCalledWith('toggleAgentTypingStatus', {
        status: true,
      });
    });
  });

  describe('#sendMessage', () => {
    it('sends correct mutations', async () => {
      const mockDate = new Date(1466424490000);
      getUuid.mockImplementationOnce(() => '1111');
      const spy = vi.spyOn(global, 'Date').mockImplementation(() => mockDate);
      const windowSpy = vi.spyOn(window, 'window', 'get');
      windowSpy.mockImplementation(() => ({
        WOOT_WIDGET: {
          $root: {
            $i18n: {
              locale: 'ar',
            },
          },
        },
        location: {
          search: '?param=1',
        },
      }));
      const state = { pendingCustomAttributes: {}, pendingLabels: [] };
      await actions.sendMessage(
        { commit, dispatch, state },
        { content: 'hello', replyTo: 124 }
      );
      spy.mockRestore();
      windowSpy.mockRestore();
      expect(dispatch).toBeCalledWith('sendMessageWithData', {
        message: {
          attachments: undefined,
          content: 'hello',
          created_at: 1466424490,
          id: '1111',
          message_type: 0,
          replyTo: 124,
          status: 'in_progress',
        },
        pendingCustomAttributes: {},
        pendingLabels: [],
      });
    });

    it('includes pending metadata when available', async () => {
      const mockDate = new Date(1466424490000);
      getUuid.mockImplementationOnce(() => '2222');
      const spy = vi.spyOn(global, 'Date').mockImplementation(() => mockDate);
      const state = {
        pendingCustomAttributes: { plan: 'enterprise' },
        pendingLabels: ['vip'],
      };
      await actions.sendMessage(
        { commit, dispatch, state },
        { content: 'hello' }
      );
      spy.mockRestore();
      expect(dispatch).toBeCalledWith('sendMessageWithData', {
        message: expect.objectContaining({ content: 'hello' }),
        pendingCustomAttributes: { plan: 'enterprise' },
        pendingLabels: ['vip'],
      });
    });
  });

  describe('#sendAttachment', () => {
    it('sends correct mutations', () => {
      const mockDate = new Date(1466424490000);
      getUuid.mockImplementationOnce(() => '1111');
      const spy = vi.spyOn(global, 'Date').mockImplementation(() => mockDate);
      const thumbUrl = '';
      const attachment = { thumbUrl, fileType: 'file' };
      const state = { pendingCustomAttributes: {}, pendingLabels: [] };

      actions.sendAttachment(
        { commit, dispatch, state },
        { attachment, replyTo: 135 }
      );
      spy.mockRestore();
      expect(commit).toBeCalledWith('pushMessageToConversation', {
        id: '1111',
        content: undefined,
        status: 'in_progress',
        created_at: 1466424490,
        message_type: 0,
        replyTo: 135,
        attachments: [
          {
            thumb_url: '',
            data_url: '',
            file_type: 'file',
            status: 'in_progress',
          },
        ],
      });
    });
  });

  describe('#setUserLastSeen', () => {
    it('sends correct mutations', async () => {
      API.post.mockResolvedValue({ data: { success: true } });
      await actions.setUserLastSeen({
        commit,
        getters: { getConversationSize: 2 },
      });
      expect(commit.mock.calls[0][0]).toEqual('setMetaUserLastSeenAt');
    });
    it('sends correct mutations', async () => {
      API.post.mockResolvedValue({ data: { success: true } });
      await actions.setUserLastSeen({
        commit,
        getters: { getConversationSize: 0 },
      });
      expect(commit.mock.calls).toEqual([]);
    });
  });

  describe('#setCustomAttributes', () => {
    it('queues to pending state when no conversation exists', async () => {
      const rootGetters = {
        'conversationAttributes/getConversationParams': { id: '' },
      };
      await actions.setCustomAttributes(
        { commit, rootGetters },
        { plan: 'enterprise' }
      );
      expect(commit).toBeCalledWith('setPendingCustomAttributes', {
        plan: 'enterprise',
      });
    });

    it('calls API when conversation exists', async () => {
      API.post.mockResolvedValue({ data: {} });
      const rootGetters = {
        'conversationAttributes/getConversationParams': { id: 123 },
      };
      await actions.setCustomAttributes(
        { commit, rootGetters },
        { plan: 'enterprise' }
      );
      expect(commit).not.toBeCalledWith(
        'setPendingCustomAttributes',
        expect.anything()
      );
    });
  });

  describe('#deleteCustomAttribute', () => {
    it('removes from pending state when no conversation exists', async () => {
      const rootGetters = {
        'conversationAttributes/getConversationParams': { id: '' },
      };
      await actions.deleteCustomAttribute({ commit, rootGetters }, 'plan');
      expect(commit).toBeCalledWith('removePendingCustomAttribute', 'plan');
    });

    it('calls API when conversation exists', async () => {
      API.post.mockResolvedValue({ data: {} });
      const rootGetters = {
        'conversationAttributes/getConversationParams': { id: 123 },
      };
      await actions.deleteCustomAttribute({ commit, rootGetters }, 'plan');
      expect(commit).not.toBeCalledWith(
        'removePendingCustomAttribute',
        expect.anything()
      );
    });
  });

  describe('#clearConversations', () => {
    it('sends correct mutations', () => {
      actions.clearConversations({ commit });
      expect(commit).toBeCalledWith('clearConversations');
    });
  });

  describe('#fetchOldConversations', () => {
    it('sends correct actions', async () => {
      API.get.mockResolvedValue({
        data: {
          payload: [
            {
              id: 1,
              text: 'hey',
              content_attributes: {},
            },
            {
              id: 2,
              text: 'welcome',
              content_attributes: { deleted: true },
            },
          ],
          meta: {
            contact_last_seen_at: 1466424490,
          },
        },
      });
      await actions.fetchOldConversations({ commit }, {});
      expect(commit.mock.calls).toEqual([
        ['setConversationListLoading', true],
        ['conversation/setMetaUserLastSeenAt', 1466424490, { root: true }],
        [
          'setMessagesInConversation',
          [
            {
              id: 1,
              text: 'hey',
              content_attributes: {},
            },
          ],
        ],
        ['setConversationListLoading', false],
      ]);
    });
  });

  describe('reconnect pagination with real mutations', () => {
    let state;
    let context;
    let missed;

    beforeEach(() => {
      API.get.mockReset();
      state = {
        conversations: { 1: { id: 1, created_at: 1 } },
        lastMessageId: 1,
        meta: {},
        uiFlags: { allMessagesLoaded: false, isFetchingList: false },
      };
      context = {
        state,
        commit: vi.fn((name, payload) => {
          mutations[name.replace('conversation/', '')](state, payload);
        }),
      };
      missed = Array.from({ length: 201 }, (_, index) => ({
        id: index + 2,
        created_at: index + 2,
        content_attributes: {},
      }));
    });

    it.each([0, 99, 100, 101, 201])(
      'recovers %i rows with bounded pages',
      async count => {
        const messages = missed.slice(0, count);
        API.get.mockImplementation(async (_, { params: { after } }) => ({
          data: {
            payload: messages
              .filter(message => message.id > after)
              .slice(0, 100),
            meta: { contact_last_seen_at: 123 },
          },
        }));
        expect(await actions.syncLatestMessages(context)).toBe(true);
        expect(
          Object.values(state.conversations).map(message => message.id)
        ).toEqual([1, ...messages.map(message => message.id)]);
        expect(API.get).toHaveBeenCalledTimes(Math.floor(count / 100) + 1);
        expect(state.lastMessageId).toBeNull();
        expect(state).not.toHaveProperty('conversation');
        expect(state.uiFlags).toEqual({
          allMessagesLoaded: false,
          isFetchingList: false,
        });
        expect(state.meta.userLastSeenAt).toBe(123);
      }
    );

    it.each(['duplicate', 'deleted'])(
      'continues through a full %s-only page',
      async kind => {
        const firstPage = missed.slice(0, 100);
        if (kind === 'duplicate') {
          firstPage.forEach(message => {
            state.conversations[message.id] = {
              ...message,
              content: 'live version',
            };
          });
        } else {
          firstPage.forEach(message => {
            message.content_attributes.deleted = true;
          });
        }
        API.get.mockResolvedValueOnce({
          data: { payload: firstPage, meta: {} },
        });
        API.get.mockResolvedValueOnce({
          data: { payload: [missed[100]], meta: {} },
        });
        expect(await actions.syncLatestMessages(context)).toBe(true);
        expect(API.get.mock.calls[1][1].params.after).toBe(101);
        expect(state.conversations[102]).toEqual(missed[100]);
        expect(Object.keys(state.conversations)).toHaveLength(
          kind === 'duplicate' ? 102 : 2
        );
        if (kind === 'duplicate') {
          expect(state.conversations[2].content).toBe('live version');
        }
      }
    );

    it.each([1, 2])(
      'retains the anchor after page %i fails and replays on retry',
      async failedPage => {
        if (failedPage === 2) {
          API.get.mockResolvedValueOnce({
            data: { payload: missed.slice(0, 100), meta: {} },
          });
        }
        API.get.mockRejectedValueOnce(new Error('offline'));
        expect(await actions.syncLatestMessages(context)).toBe(false);
        expect(state.lastMessageId).toBe(1);
        expect(context.commit).not.toHaveBeenCalledWith('clearLastMessageId');
        await actions.addOrUpdateMessage(context, { id: 500, created_at: 500 });
        await actions.setLastMessageId(context);
        expect(state.lastMessageId).toBe(1);
        API.get.mockReset();
        API.get.mockImplementation(async (_, { params: { after } }) => ({
          data: {
            payload: missed.filter(message => message.id > after).slice(0, 100),
            meta: {},
          },
        }));
        expect(await actions.syncLatestMessages(context)).toBe(true);
        expect(API.get.mock.calls[0][1].params.after).toBe(1);
        expect(Object.keys(state.conversations)).toHaveLength(203);
        expect(state.conversations[500]).toEqual({ id: 500, created_at: 500 });
        expect(state.lastMessageId).toBeNull();
      }
    );

    it('keeps recovery pending and preserves live arrivals during a later page', async () => {
      let resolvePage;
      API.get.mockResolvedValueOnce({
        data: { payload: missed.slice(0, 100), meta: {} },
      });
      API.get.mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolvePage = resolve;
          })
      );
      const recovery = actions.syncLatestMessages(context);
      await vi.waitFor(() => expect(API.get).toHaveBeenCalledTimes(2));
      expect(state.lastMessageId).toBe(1);
      expect(context.commit).not.toHaveBeenCalledWith('clearLastMessageId');
      await actions.addOrUpdateMessage(context, { id: 500, created_at: 500 });
      resolvePage({ data: { payload: [missed[100]], meta: {} } });
      expect(await recovery).toBe(true);
      expect(state.conversations[500]).toEqual({ id: 500, created_at: 500 });
      expect(state.conversations[102]).toEqual(missed[100]);
      expect(state.lastMessageId).toBeNull();
    });

    it('discards a response when the conversation was cleared in flight', async () => {
      let resolvePage;
      API.get.mockImplementationOnce(
        () =>
          new Promise(resolve => {
            resolvePage = resolve;
          })
      );
      const recovery = actions.syncLatestMessages(context);
      actions.clearConversations(context);
      await actions.addOrUpdateMessage(context, { id: 900, created_at: 900 });
      resolvePage({ data: { payload: missed.slice(0, 100), meta: {} } });
      expect(await recovery).toBe(false);
      expect(state.conversations).toEqual({
        900: { id: 900, created_at: 900 },
      });
      expect(state.lastMessageId).toBeNull();
      expect(API.get).toHaveBeenCalledTimes(1);
    });

    it('fails without clearing the anchor when a page cannot advance', async () => {
      API.get.mockResolvedValueOnce({
        data: { payload: [{ id: 1 }], meta: {} },
      });
      expect(await actions.syncLatestMessages(context)).toBe(false);
      expect(state.lastMessageId).toBe(1);
      expect(context.commit).not.toHaveBeenCalledWith('clearLastMessageId');
    });

    it('uses one latest-page fetch when there is no saved anchor', async () => {
      state.lastMessageId = null;
      API.get.mockResolvedValueOnce({
        data: { payload: missed.slice(0, 100), meta: {} },
      });
      expect(await actions.syncLatestMessages(context)).toBe(true);
      expect(API.get).toHaveBeenCalledTimes(1);
      expect(API.get.mock.calls[0][1].params.after).toBeNull();
      expect(Object.keys(state.conversations)).toHaveLength(101);
    });
  });

  describe('#syncLatestMessages', () => {
    it('latest message should append to end of list', async () => {
      const state = {
        uiFlags: { allMessagesLoaded: false },
        conversations: {
          454: {
            id: 454,
            content: 'hi',
            message_type: 0,
            content_type: 'text',
            content_attributes: {},
            created_at: 1682244355, //  Sunday, 23 April 2023 10:05:55
            conversation_id: 20,
          },
          463: {
            id: 463,
            content: 'ss',
            message_type: 0,
            content_type: 'text',
            content_attributes: {},
            created_at: 1682490729, // Wednesday, 26 April 2023 06:32:09
            conversation_id: 20,
          },
        },
        lastMessageId: 463,
      };
      API.get.mockResolvedValue({
        data: {
          payload: [
            {
              id: 465,
              content: 'hi',
              message_type: 0,
              content_type: 'text',
              content_attributes: {},
              created_at: 1682504326, // Wednesday, 26 April 2023 10:18:46
              conversation_id: 20,
            },
          ],
          meta: {
            contact_last_seen_at: 1466424490,
          },
        },
      });
      await actions.syncLatestMessages({ state, commit }, {});
      expect(commit.mock.calls).toEqual([
        ['conversation/setMetaUserLastSeenAt', 1466424490, { root: true }],
        [
          'setMissingMessagesInConversation',

          {
            454: {
              id: 454,
              content: 'hi',
              message_type: 0,
              content_type: 'text',
              content_attributes: {},
              created_at: 1682244355,
              conversation_id: 20,
            },
            463: {
              id: 463,
              content: 'ss',
              message_type: 0,
              content_type: 'text',
              content_attributes: {},
              created_at: 1682490729,
              conversation_id: 20,
            },
            465: {
              id: 465,
              content: 'hi',
              message_type: 0,
              content_type: 'text',
              content_attributes: {},
              created_at: 1682504326,
              conversation_id: 20,
            },
          },
        ],
        ['clearLastMessageId'],
      ]);
    });

    it('old message should insert to exact position', async () => {
      const state = {
        uiFlags: { allMessagesLoaded: false },
        conversations: {
          454: {
            id: 454,
            content: 'hi',
            message_type: 0,
            content_type: 'text',
            content_attributes: {},
            created_at: 1682244355, //  Sunday, 23 April 2023 10:05:55
            conversation_id: 20,
          },
          463: {
            id: 463,
            content: 'ss',
            message_type: 0,
            content_type: 'text',
            content_attributes: {},
            created_at: 1682490729, // Wednesday, 26 April 2023 06:32:09
            conversation_id: 20,
          },
        },
        lastMessageId: 463,
      };
      API.get.mockResolvedValue({
        data: {
          payload: [
            {
              id: 465,
              content: 'Hi how are you',
              message_type: 0,
              content_type: 'text',
              content_attributes: {},
              created_at: 1682417926, // Tuesday, 25 April 2023 10:18:46
              conversation_id: 20,
            },
          ],
          meta: {
            contact_last_seen_at: 14664223490,
          },
        },
      });
      await actions.syncLatestMessages({ state, commit }, {});

      expect(commit.mock.calls).toEqual([
        ['conversation/setMetaUserLastSeenAt', 14664223490, { root: true }],
        [
          'setMissingMessagesInConversation',

          {
            454: {
              id: 454,
              content: 'hi',
              message_type: 0,
              content_type: 'text',
              content_attributes: {},
              created_at: 1682244355,
              conversation_id: 20,
            },
            465: {
              id: 465,
              content: 'Hi how are you',
              message_type: 0,
              content_type: 'text',
              content_attributes: {},
              created_at: 1682417926,
              conversation_id: 20,
            },
            463: {
              id: 463,
              content: 'ss',
              message_type: 0,
              content_type: 'text',
              content_attributes: {},
              created_at: 1682490729,
              conversation_id: 20,
            },
          },
        ],
        ['clearLastMessageId'],
      ]);
    });

    it('finishes syncing when there are no missing messages', async () => {
      const state = {
        uiFlags: { allMessagesLoaded: false },
        conversations: {
          454: {
            id: 454,
            content: 'hi',
            message_type: 0,
            content_type: 'text',
            content_attributes: {},
            created_at: 1682244355, //  Sunday, 23 April 2023 10:05:55
            conversation_id: 20,
          },
          463: {
            id: 463,
            content: 'ss',
            message_type: 0,
            content_type: 'text',
            content_attributes: {},
            created_at: 1682490729, // Wednesday, 26 April 2023 06:32:09
            conversation_id: 20,
          },
        },
        lastMessageId: 463,
      };
      API.get.mockResolvedValue({
        data: {
          payload: [],
          meta: {
            contact_last_seen_at: 14664223490,
          },
        },
      });
      await actions.syncLatestMessages({ state, commit }, {});

      expect(commit.mock.calls).toEqual([
        ['conversation/setMetaUserLastSeenAt', 14664223490, { root: true }],
        ['setMissingMessagesInConversation', state.conversations],
        ['clearLastMessageId'],
      ]);
    });
  });
});
