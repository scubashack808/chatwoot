import { shallowMount, flushPromises } from '@vue/test-utils';
import { computed, ref } from 'vue';
import ChatList from '../ChatList.vue';
import { BUS_EVENTS } from 'shared/constants/busEvents';

const mocks = vi.hoisted(() => ({
  handlers: {},
  dispatch: vi.fn(() => Promise.resolve()),
  push: vi.fn(() => Promise.resolve()),
  featureEnabled: true,
  loadedConversationIds: [],
  route: {
    name: 'inbox_conversation',
    params: { accountId: 1, inbox_id: 2, conversation_id: 42 },
  },
}));

vi.mock('vue-router', () => ({
  useRoute: () => mocks.route,
  useRouter: () => ({ push: mocks.push }),
}));
vi.mock('vuex', async importOriginal => ({
  ...(await importOriginal()),
  useStore: () => ({
    dispatch: mocks.dispatch,
    getters: {
      'inboxes/getInbox': () => ({ channel_type: 'Channel::Email' }),
      'accounts/isFeatureEnabledonAccount': () => mocks.featureEnabled,
    },
  }),
}));
vi.mock('dashboard/composables/store.js', () => ({
  useMapGetter: key =>
    computed(() => {
      if (key === 'getCurrentUser')
        return {
          id: 1,
          accounts: [
            { id: 1, role: 'administrator', permissions: ['administrator'] },
          ],
        };
      if (key === 'getCurrentAccountId') return 1;
      if (key === 'conversationStats/getStats') return { mine_count: 0 };
      if (key === 'getConversationById')
        return id =>
          mocks.loadedConversationIds.includes(id) ? { id } : undefined;
      return [];
    }),
  useFunctionGetter: key =>
    computed(() => {
      if (key === 'inboxes/getInbox') return {};
      if (key === 'conversationPage/getCurrentPageFilter') return 1;
      return [];
    }),
}));
vi.mock('dashboard/composables/emitter', () => ({
  useEmitter: (event, handler) => {
    mocks.handlers[event] = handler;
  },
}));
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({ uiSettings: ref({}) }),
}));
vi.mock('dashboard/composables/chatlist/useBulkActions', () => ({
  useBulkActions: () => ({
    selectedConversations: ref([]),
    selectedInboxes: ref([]),
    resetBulkActions: vi.fn(),
  }),
}));
vi.mock('shared/composables/useFilter', () => ({ useFilter: () => ({}) }));
vi.mock('dashboard/composables/useConversationRequiredAttributes', () => ({
  useConversationRequiredAttributes: () => ({
    checkMissingAttributes: vi.fn(),
  }),
}));
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));

const MAILBOX_EVENT = BUS_EVENTS.MAILBOX_OPERATION_UPDATED;
const dispatchedActions = name =>
  mocks.dispatch.mock.calls.filter(([action]) => action === name);
const RESET_ACTIONS = [
  'emptyAllConversations',
  'conversationPage/reset',
  'clearConversationFilters',
  'bulkActions/clearSelectedConversationIds',
];

// Renderless mount exercises ChatList's actual setup and registered event handler.
describe('ChatList mailbox publication', () => {
  let wrapper;
  const mountChatList = async () => {
    wrapper = shallowMount(
      { ...ChatList, render: () => null },
      { props: { conversationInbox: 2, mailboxRole: 'inbox' } }
    );
    await flushPromises();
    mocks.dispatch.mockClear();
    mocks.push.mockClear();
  };
  const publishState = (conversationId, mailboxState) =>
    mocks.handlers[MAILBOX_EVENT]({
      conversationId,
      stateOnly: true,
      mailboxState,
    });

  beforeEach(async () => {
    vi.useFakeTimers();
    mocks.featureEnabled = true;
    mocks.loadedConversationIds = [];
    await mountChatList();
  });
  afterEach(() => {
    wrapper.unmount();
    vi.useRealTimers();
  });

  it('coalesces a burst of state-only events into one non-destructive refresh', async () => {
    for (let id = 1000; id < 1020; id += 1) {
      // eslint-disable-next-line no-await-in-loop
      await publishState(id, { state: 'archive', roles: ['archive'] });
    }
    expect(dispatchedActions('fetchAllConversations')).toHaveLength(0);

    await vi.runAllTimersAsync();

    expect(dispatchedActions('fetchAllConversations')).toHaveLength(1);
    expect(dispatchedActions('updateChatListFilters')).toEqual([
      [
        'updateChatListFilters',
        expect.objectContaining({ inboxId: 2, mailboxRole: 'inbox', page: 1 }),
      ],
    ]);
    RESET_ACTIONS.forEach(action =>
      expect(dispatchedActions(action)).toHaveLength(0)
    );
    expect(mocks.push).not.toHaveBeenCalled();
  });

  it.each(['inbox', 'archive', 'trash'])(
    'refreshes membership for an unloaded conversation moved to %s',
    async role => {
      await publishState(999, { state: role, roles: [role] });
      await vi.runAllTimersAsync();
      expect(dispatchedActions('fetchAllConversations')).toHaveLength(1);
      expect(dispatchedActions('removeConversationFromList')).toHaveLength(0);
      expect(mocks.push).not.toHaveBeenCalled();
    }
  );

  it('drops a loaded conversation that left the active role without resetting the list', async () => {
    mocks.loadedConversationIds = [7];
    await publishState(7, { state: 'trash', roles: ['trash'] });
    expect(mocks.dispatch).toHaveBeenCalledWith(
      'removeConversationFromList',
      7
    );
    expect(mocks.dispatch).toHaveBeenCalledWith(
      'bulkActions/removeSelectedConversationIds',
      7
    );
    RESET_ACTIONS.forEach(action =>
      expect(dispatchedActions(action)).toHaveLength(0)
    );
  });

  it('leaves the selected conversation immediately when its placement leaves the active role', async () => {
    mocks.loadedConversationIds = [42];
    await publishState(42, { state: 'archive', roles: ['archive'] });
    expect(mocks.push).toHaveBeenCalledOnce();
    expect(mocks.dispatch).toHaveBeenCalledWith(
      'removeConversationFromList',
      42
    );
    await vi.runAllTimersAsync();
    expect(dispatchedActions('fetchAllConversations')).toHaveLength(1);
  });

  it.each(['inbox', 'archive', 'trash'])(
    'keeps the selected conversation in its current %s role',
    async role => {
      mocks.loadedConversationIds = [42];
      await wrapper.setProps({ mailboxRole: role });
      await flushPromises();
      mocks.dispatch.mockClear();
      mocks.push.mockClear();
      await publishState(42, { state: role, roles: [role] });
      await vi.runAllTimersAsync();
      expect(mocks.push).not.toHaveBeenCalled();
      expect(dispatchedActions('removeConversationFromList')).toHaveLength(0);
      expect(dispatchedActions('updateChatListFilters')).toEqual([
        [
          'updateChatListFilters',
          expect.objectContaining({ mailboxRole: role, page: 1 }),
        ],
      ]);
    }
  );

  it('refreshes invalidated state without inventing navigation or removal', async () => {
    mocks.loadedConversationIds = [42];
    await publishState(42, undefined);
    await vi.runAllTimersAsync();
    expect(mocks.push).not.toHaveBeenCalled();
    expect(dispatchedActions('removeConversationFromList')).toHaveLength(0);
    expect(dispatchedActions('fetchAllConversations')).toHaveLength(1);
  });

  it('cancels a pending refresh when the list unmounts', async () => {
    await publishState(999, { state: 'archive', roles: ['archive'] });
    wrapper.unmount();
    await vi.runAllTimersAsync();
    expect(dispatchedActions('fetchAllConversations')).toHaveLength(0);
    await mountChatList();
  });

  it('preserves terminal forward operation navigation and refresh', async () => {
    await mocks.handlers[MAILBOX_EVENT]({
      conversationId: 42,
      mailboxOperation: { id: 90, status: 'succeeded' },
      mailboxState: { state: 'trash', roles: ['trash'] },
    });
    expect(mocks.push).toHaveBeenCalledOnce();
    expect(mocks.dispatch).toHaveBeenCalledWith('emptyAllConversations');
    expect(mocks.dispatch).toHaveBeenCalledWith('fetchAllConversations');
  });

  it('does not refresh for a nonterminal forward operation', async () => {
    await mocks.handlers[MAILBOX_EVENT]({
      conversationId: 42,
      mailboxOperation: { id: 90, status: 'running' },
    });
    await vi.runAllTimersAsync();
    expect(mocks.dispatch).not.toHaveBeenCalled();
    expect(mocks.push).not.toHaveBeenCalled();
  });

  it('does not enable role refresh where the feature is disabled', async () => {
    wrapper.unmount();
    mocks.featureEnabled = false;
    await mountChatList();
    await publishState(999, { state: 'archive' });
    await vi.runAllTimersAsync();
    expect(mocks.dispatch).not.toHaveBeenCalled();
  });
});
