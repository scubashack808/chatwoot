import { createStore } from 'vuex';
import ConversationApi from '../../../../api/inbox/conversation';
import conversations from '../../conversations';
import conversationPage from '../../conversationPage';

vi.mock('../../../../api/inbox/conversation', () => ({
  default: { get: vi.fn() },
}));

const rows = (start, count) =>
  Array.from({ length: count }, (_, index) => ({
    id: start + index,
    meta: { sender: { id: start + index } },
  }));

// Use the actual fetch action, merge mutation, buildConversationList helper and
// pagination module; only the API and unrelated contacts/labels are substituted.
describe('mailbox refresh pagination', () => {
  let store;
  beforeEach(() => {
    vi.clearAllMocks();
    store = createStore({
      modules: {
        conversations: {
          ...conversations,
          state: {
            ...structuredClone(conversations.state),
            conversationFilters: { page: 1, assigneeType: 'all' },
          },
        },
        conversationPage: {
          ...conversationPage,
          state: structuredClone(conversationPage.state),
        },
        conversationStats: {
          namespaced: true,
          actions: { set: vi.fn() },
        },
        conversationLabels: {
          namespaced: true,
          actions: { setBulkConversationLabels: vi.fn() },
        },
        contacts: {
          namespaced: true,
          mutations: { SET_CONTACTS: vi.fn() },
        },
      },
    });
  });

  it('reopens an exhausted list and loads the remainder of 40 external arrivals', async () => {
    await store.dispatch('conversationPage/setCurrentPage', {
      filter: 'all',
      page: 1,
    });
    await store.dispatch('conversationPage/setEndReached', { filter: 'all' });
    ConversationApi.get.mockImplementation(({ page }) =>
      Promise.resolve({
        data: {
          data: {
            payload: page === 1 ? rows(1, 25) : rows(26, 15),
            meta: { all_count: 40 },
          },
        },
      })
    );

    await store.dispatch('fetchAllConversations', { refreshPages: 1 });

    expect(store.state.conversationPage.hasEndReached).toEqual({
      all: false,
      me: false,
      unassigned: false,
    });
    expect(store.state.conversations.allConversations).toHaveLength(25);
    const page = store.getters['conversationPage/getCurrentPageFilter']('all');
    await store.dispatch('updateChatListFilters', { page: page + 1 });
    await store.dispatch('fetchAllConversations');
    expect(store.state.conversations.allConversations).toHaveLength(40);
    expect(store.state.conversationPage.currentPage.all).toBe(2);
  });

  it('refills all retained pages without rewinding the load-more cursor or clearing selection', async () => {
    store.state.conversations.allConversations = rows(100, 75);
    store.state.conversations.selectedChatId = 100;
    store.state.conversations.appliedFilters = [{ attribute_key: 'status' }];
    await store.dispatch('conversationPage/setCurrentPage', {
      filter: 'all',
      page: 3,
    });
    ConversationApi.get.mockImplementation(({ page }) =>
      Promise.resolve({
        data: {
          data: { payload: rows((page - 1) * 25 + 1, 25), meta: {} },
        },
      })
    );

    await store.dispatch('fetchAllConversations', { refreshPages: 3 });

    expect(
      ConversationApi.get.mock.calls.map(([params]) => params.page)
    ).toEqual([1, 2, 3]);
    expect(store.state.conversationPage.currentPage.all).toBe(3);
    expect(store.state.conversations.allConversations).toHaveLength(150);
    expect(store.state.conversations.selectedChatId).toBe(100);
    expect(store.state.conversations.appliedFilters).toEqual([
      { attribute_key: 'status' },
    ]);
    await store.dispatch('updateChatListFilters', {
      page: store.state.conversationPage.currentPage.all + 1,
    });
    await store.dispatch('fetchAllConversations');
    expect(ConversationApi.get).toHaveBeenLastCalledWith({
      page: 4,
      assigneeType: 'all',
    });
  });

  it('keeps exhaustion when the final retained page is still empty', async () => {
    ConversationApi.get.mockImplementation(({ page }) =>
      Promise.resolve({
        data: { data: { payload: page === 1 ? rows(1, 5) : [], meta: {} } },
      })
    );
    await store.dispatch('fetchAllConversations', { refreshPages: 2 });
    expect(store.state.conversationPage.currentPage.all).toBe(2);
    expect(store.state.conversationPage.hasEndReached.all).toBe(true);
  });
});
