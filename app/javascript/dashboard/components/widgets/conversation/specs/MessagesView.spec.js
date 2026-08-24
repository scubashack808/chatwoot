import { shallowMount } from '@vue/test-utils';
import { nextTick } from 'vue';
import { createStore } from 'vuex';
import MessagesView from '../MessagesView.vue';

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '1' }, query: {} }),
}));

const chat = (id, inboxId) => ({
  id,
  inbox_id: inboxId,
  can_reply: true,
  status: 'open',
  messages: [],
  labels: [],
  unread_count: 0,
  additional_attributes: {},
});

const buildStore = () =>
  createStore({
    state: {
      chat: chat(1, 1),
      inboxes: {
        1: { id: 1, channel_type: 'Channel::Email' },
        2: { id: 2, channel_type: 'Channel::WebWidget' },
      },
    },
    mutations: {
      selectChat: (state, selectedChat) => {
        state.chat = selectedChat;
      },
    },
    actions: {
      fetchAllAttachments: vi.fn(),
      'integrations/get': vi.fn(),
    },
    getters: {
      getSelectedChat: state => state.chat,
      getCurrentUserID: () => 1,
      getAllMessagesLoaded: () => true,
      getCurrentAccountId: () => 1,
      'accounts/getAccount': () => () => ({ id: 1 }),
      'accounts/isFeatureEnabledonAccount': () => () => false,
      'globalConfig/isOnChatwootCloud': () => false,
      'globalConfig/isMetaInboxCreationDisabled': () => false,
      'globalConfig/isMetaMessageSendingDisabled': () => false,
      'inboxes/getInbox': state => inboxId => state.inboxes[inboxId],
      'inboxes/getInstagramInboxByInstagramId': () => () => null,
      'integrations/getAppIntegrations': () => [],
      'conversationTypingStatus/getUserList': () => () => [],
    },
  });

const editorHeight = wrapper =>
  wrapper
    .get('.resizable-editor-wrapper')
    .element.style.getPropertyValue('--editor-height');

const mountView = () => {
  const store = buildStore();
  const wrapper = shallowMount(MessagesView, {
    global: {
      plugins: [store],
      mocks: { $t: key => key, $route: { query: {} } },
      stubs: {
        MessageList: {
          template:
            '<div><slot name="beforeAll"/><slot name="unreadBadge"/><slot name="after"/></div>',
        },
        ResizableEditorWrapper: false,
      },
    },
  });
  return { store, wrapper };
};

describe('MessagesView reply editor height', () => {
  it('uses the compact height for email and the upstream height for other inboxes', async () => {
    const { store, wrapper } = mountView();

    expect(editorHeight(wrapper)).toBe('80px');

    store.commit('selectChat', chat(2, 2));
    await nextTick();
    await nextTick();

    expect(editorHeight(wrapper)).toBe('120px');

    store.commit('selectChat', chat(3, 1));
    await nextTick();
    await nextTick();

    expect(editorHeight(wrapper)).toBe('80px');
  });
});
