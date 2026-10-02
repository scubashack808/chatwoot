import { shallowMount, flushPromises } from '@vue/test-utils';
import { computed, ref } from 'vue';
import ChatList from '../ChatList.vue';
import { BUS_EVENTS } from 'shared/constants/busEvents';

const mocks = vi.hoisted(() => ({
  handlers: {},
  dispatch: vi.fn(() => Promise.resolve()),
  push: vi.fn(() => Promise.resolve()),
  featureEnabled: true,
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
      if (key === 'getConversationById') return () => undefined;
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

// Renderless mount exercises ChatList's actual setup and registered event handler.
describe('ChatList mailbox publication', () => {
  let wrapper;
  beforeEach(async () => {
    mocks.featureEnabled = true;
    wrapper = shallowMount(
      { ...ChatList, render: () => null },
      {
        props: { conversationInbox: 2, mailboxRole: 'inbox' },
      }
    );
    await flushPromises();
    mocks.dispatch.mockClear();
    mocks.push.mockClear();
  });
  afterEach(() => wrapper.unmount());

  it.each(['inbox', 'archive', 'trash'])(
    'refreshes membership and role-filtered counts for an unloaded conversation moved to %s',
    async role => {
      await mocks.handlers[BUS_EVENTS.MAILBOX_OPERATION_UPDATED]({
        conversationId: 999,
        stateOnly: true,
        mailboxState: { state: role, roles: [role] },
      });
      expect(mocks.dispatch).toHaveBeenCalledWith('fetchAllConversations');
      expect(mocks.dispatch).toHaveBeenCalledWith(
        'conversationStats/get',
        expect.objectContaining({ inboxId: 2, mailboxRole: 'inbox' })
      );
      expect(mocks.push).not.toHaveBeenCalled();
    }
  );

  it('leaves the selected conversation when its concrete placement leaves the active role', async () => {
    await mocks.handlers[BUS_EVENTS.MAILBOX_OPERATION_UPDATED]({
      conversationId: 42,
      stateOnly: true,
      mailboxState: { state: 'archive', roles: ['archive'] },
    });
    expect(mocks.push).toHaveBeenCalledOnce();
    expect(mocks.dispatch).toHaveBeenCalledWith('fetchAllConversations');
  });

  it.each(['inbox', 'archive', 'trash'])(
    'keeps the selected conversation in its current %s role while refreshing counts',
    async role => {
      await wrapper.setProps({ mailboxRole: role });
      await flushPromises();
      mocks.dispatch.mockClear();
      mocks.push.mockClear();
      await mocks.handlers[BUS_EVENTS.MAILBOX_OPERATION_UPDATED]({
        conversationId: 42,
        stateOnly: true,
        mailboxState: { state: role, roles: [role] },
      });
      expect(mocks.push).not.toHaveBeenCalled();
      expect(mocks.dispatch).toHaveBeenCalledWith('fetchAllConversations');
      expect(mocks.dispatch).toHaveBeenCalledWith(
        'conversationStats/get',
        expect.objectContaining({ inboxId: 2, mailboxRole: role })
      );
    }
  );

  it('refreshes invalidated state without inventing navigation', async () => {
    await mocks.handlers[BUS_EVENTS.MAILBOX_OPERATION_UPDATED]({
      conversationId: 42,
      stateOnly: true,
    });
    expect(mocks.push).not.toHaveBeenCalled();
    expect(mocks.dispatch).toHaveBeenCalledWith('fetchAllConversations');
    expect(mocks.dispatch).toHaveBeenCalledWith(
      'conversationStats/get',
      expect.objectContaining({ mailboxRole: 'inbox' })
    );
  });

  it('preserves terminal forward operation navigation and refresh', async () => {
    await mocks.handlers[BUS_EVENTS.MAILBOX_OPERATION_UPDATED]({
      conversationId: 42,
      mailboxOperation: { id: 90, status: 'succeeded' },
      mailboxState: { state: 'trash', roles: ['trash'] },
    });
    expect(mocks.push).toHaveBeenCalledOnce();
    expect(mocks.dispatch).toHaveBeenCalledWith('fetchAllConversations');
  });

  it('does not refresh for a nonterminal forward operation', async () => {
    await mocks.handlers[BUS_EVENTS.MAILBOX_OPERATION_UPDATED]({
      conversationId: 42,
      mailboxOperation: { id: 90, status: 'running' },
    });
    expect(mocks.dispatch).not.toHaveBeenCalled();
    expect(mocks.push).not.toHaveBeenCalled();
  });

  it('does not enable role refresh where the feature is disabled', async () => {
    wrapper.unmount();
    mocks.featureEnabled = false;
    wrapper = shallowMount(
      { ...ChatList, render: () => null },
      {
        props: { conversationInbox: 2, mailboxRole: 'inbox' },
      }
    );
    await flushPromises();
    mocks.dispatch.mockClear();
    await mocks.handlers[BUS_EVENTS.MAILBOX_OPERATION_UPDATED]({
      conversationId: 999,
      stateOnly: true,
      mailboxState: { state: 'archive' },
    });
    expect(mocks.dispatch).not.toHaveBeenCalled();
  });
});
