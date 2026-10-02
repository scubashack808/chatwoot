import { createStore } from 'vuex';
import conversations from 'dashboard/store/modules/conversations';
import conversationStats from 'dashboard/store/modules/conversationStats';
import conversationPage from 'dashboard/store/modules/conversationPage';
import ConversationApi from 'dashboard/api/inbox/conversation';
import types from 'dashboard/store/mutation-types';

describe('conversation list request ownership', () => {
  let store;
  let requests;
  const archive = {
    id: 11,
    inbox_id: 1,
    status: 'open',
    labels: [],
    meta: { sender: { id: 101 }, assignee: null },
    mailbox_state: { state: 'archive', roles: ['archive'] },
    messages: [{ id: 110, message_type: 0, private: false }],
  };
  const sent = {
    ...archive,
    id: 22,
    meta: { sender: { id: 102 }, assignee: null },
    mailbox_state: null,
    messages: [{ id: 220, message_type: 1, private: false }],
  };
  const sentFilters = {
    inboxId: 1,
    assigneeType: 'all',
    status: 'all',
    page: 1,
    mailboxRole: 'sent',
  };
  const archiveData = { payload: [archive], meta: { all_count: 9 } };
  const sentData = { payload: [sent], meta: { all_count: 1 } };

  beforeEach(() => {
    requests = [];
    store = createStore({
      ...conversations,
      state: {
        ...conversations.state,
        allConversations: [],
        selectedChatId: null,
        conversationFilters: { ...sentFilters, mailboxRole: 'archive' },
      },
      getters: {
        ...conversations.getters,
        getCurrentUser: () => ({
          id: 7,
          accounts: [{ id: 1, role: 'administrator' }],
        }),
        getCurrentAccountId: () => 1,
      },
      modules: {
        conversationStats: {
          ...conversationStats,
          state: { mineCount: 0, unAssignedCount: 0, allCount: 0 },
        },
        conversationPage: {
          ...conversationPage,
          state: {
            currentPage: { all: 0 },
            hasEndReached: { all: false },
          },
        },
        contacts: {
          namespaced: true,
          mutations: { [types.SET_CONTACTS]: vi.fn() },
        },
        conversationLabels: {
          namespaced: true,
          actions: { setBulkConversationLabels: vi.fn() },
        },
      },
    });
    // Intentionally ignore cancellation: even a transport that resolves late
    // must not be allowed to commit a superseded response.
    vi.spyOn(ConversationApi, 'get').mockImplementation(
      (params, options) =>
        new Promise((resolve, reject) => {
          requests.push({ params, ...options, resolve, reject });
        })
    );
    vi.spyOn(ConversationApi, 'filter').mockImplementation(
      (params, options) =>
        new Promise((resolve, reject) => {
          requests.push({ params, ...options, resolve, reject });
        })
    );
  });

  afterEach(() => vi.restoreAllMocks());

  it.each(['membership', 'counts', 'page', 'end state'])(
    'ignores late Archive %s after Sent settles',
    async field => {
      await store.dispatch('updateChatListFilters', {
        ...sentFilters,
        mailboxRole: 'archive',
        page: 7,
      });
      const oldRequest = store.dispatch('fetchAllConversations');
      await store.dispatch('conversationPage/reset');
      await store.dispatch('emptyAllConversations');
      await store.dispatch('clearConversationFilters');
      await store.dispatch('updateChatListFilters', sentFilters);
      const currentRequest = store.dispatch('fetchAllConversations');
      requests[1].resolve({ data: { data: sentData } });
      await currentRequest;
      requests[0].resolve({
        data: {
          data:
            field === 'end state'
              ? { ...archiveData, payload: [] }
              : archiveData,
        },
      });
      await oldRequest;

      if (field === 'membership') {
        expect(
          store.getters.getAllStatusChats(sentFilters).map(c => c.id)
        ).toEqual([22]);
      } else if (field === 'counts') {
        expect(store.state.conversationStats.allCount).toBe(1);
      } else if (field === 'page') {
        expect(
          store.getters['conversationPage/getCurrentPageFilter']('all')
        ).toBe(1);
      } else {
        expect(store.getters['conversationPage/getHasEndReached']('all')).toBe(
          false
        );
      }
    }
  );

  it('keeps loading owned by Sent while a stale Archive response settles', async () => {
    const oldRequest = store.dispatch('fetchAllConversations');
    await store.dispatch('updateChatListFilters', sentFilters);
    const currentRequest = store.dispatch('fetchAllConversations');
    requests[0].resolve({ data: { data: archiveData } });
    await oldRequest;
    expect.soft(store.state.listLoadingStatus).toBe(true);
    requests[1].resolve({ data: { data: sentData } });
    await currentRequest;
    expect(store.state.listLoadingStatus).toBe(false);
  });

  it('preserves settled navigation and subsequent Sent pagination', async () => {
    const oldRequest = store.dispatch('fetchAllConversations');
    requests[0].resolve({ data: { data: archiveData } });
    await oldRequest;
    await store.dispatch('emptyAllConversations');
    await store.dispatch('updateChatListFilters', sentFilters);
    const currentRequest = store.dispatch('fetchAllConversations');
    requests[1].resolve({ data: { data: sentData } });
    await currentRequest;
    expect(store.getters.getAllStatusChats(sentFilters).map(c => c.id)).toEqual(
      [22]
    );
    expect(store.state.conversationStats.allCount).toBe(1);

    await store.dispatch('updateChatListFilters', { ...sentFilters, page: 2 });
    const nextPage = store.dispatch('fetchAllConversations');
    expect(requests[2].params).toEqual({ ...sentFilters, page: 2 });
    requests[2].resolve({
      data: {
        data: { payload: [{ ...sent, id: 23 }], meta: { all_count: 2 } },
      },
    });
    await nextPage;
    expect(store.getters.getAllStatusChats(sentFilters).map(c => c.id)).toEqual(
      [22, 23]
    );
    expect(store.getters['conversationPage/getCurrentPageFilter']('all')).toBe(
      2
    );
  });

  it('invalidates pending data when switching to a cached tab without fetching', async () => {
    const pending = store.dispatch('fetchAllConversations');
    await store.dispatch('invalidateConversationListRequests');
    expect(requests[0].signal.aborted).toBe(true);
    expect(store.state.listLoadingStatus).toBe(false);
    requests[0].resolve({ data: { data: archiveData } });
    await pending;
    expect(store.state.allConversations).toEqual([]);
    expect(store.state.conversationStats.allCount).toBe(0);
  });

  it.each(['resolve', 'reject'])(
    'shares ownership when an old filtered request later %ss',
    async settle => {
      const oldRequest = store.dispatch('fetchFilteredConversations', {
        page: 8,
        queryData: {},
      });
      await store.dispatch('updateChatListFilters', sentFilters);
      const currentRequest = store.dispatch('fetchAllConversations');
      expect(requests[0].signal.aborted).toBe(true);
      if (settle === 'resolve') {
        requests[0].resolve({ data: archiveData });
      } else {
        requests[0].reject(new Error('late failure'));
      }
      await expect(oldRequest).resolves.toBeUndefined();
      expect(store.state.listLoadingStatus).toBe(true);
      expect(store.state.allConversations).toEqual([]);
      requests[1].resolve({ data: { data: sentData } });
      await currentRequest;
      expect(store.state.conversationStats.allCount).toBe(1);
    }
  );

  it('lets a filtered request supersede the standard mailbox list', async () => {
    const oldRequest = store.dispatch('fetchAllConversations');
    const currentRequest = store.dispatch('fetchFilteredConversations', {
      page: 1,
      queryData: {},
    });
    requests[1].resolve({ data: sentData });
    await currentRequest;
    requests[0].resolve({ data: { data: archiveData } });
    await oldRequest;
    expect(store.state.allConversations.map(c => c.id)).toEqual([22]);
    expect(store.state.conversationStats.allCount).toBe(1);
  });
});
