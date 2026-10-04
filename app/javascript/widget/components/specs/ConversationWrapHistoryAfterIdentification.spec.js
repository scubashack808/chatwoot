import { createStore } from 'vuex';
import { flushPromises } from '@vue/test-utils';
import { API } from 'widget/helpers/axios';
import conversation from 'widget/store/modules/conversation';
import contacts from 'widget/store/modules/contacts';
import ConversationWrap from '../ConversationWrap.vue';

vi.mock('widget/helpers/axios', () => ({
  API: { get: vi.fn(), patch: vi.fn(), post: vi.fn() },
  setHeader: vi.fn(),
}));

const MESSAGES_URL = '/api/v1/widget/messages';

const messagesBetween = (first, last) =>
  Array.from({ length: last - first + 1 }, (_, index) => ({
    id: first + index,
    content: `Message ${first + index}`,
    created_at: first + index,
  }));

const page = payload => ({ data: { payload, meta: {} } });

const messageRequests = () =>
  API.get.mock.calls.filter(([url]) => url === MESSAGES_URL);

const buildStore = () =>
  createStore({
    modules: {
      conversation: {
        ...conversation,
        state: structuredClone(conversation.state),
      },
      contacts: { ...contacts, state: { currentUser: {} } },
      conversationAttributes: {
        namespaced: true,
        getters: { getConversationParams: () => ({}) },
        actions: { getAttributes: vi.fn() },
      },
    },
  });

const scrollToTop = store => {
  const { getters } = store;
  ConversationWrap.methods.handleScroll.call({
    get isFetchingList() {
      return getters['conversation/getIsFetchingList'];
    },
    get allMessagesLoaded() {
      return getters['conversation/getAllMessagesLoaded'];
    },
    get conversationSize() {
      return getters['conversation/getConversationSize'];
    },
    get earliestMessage() {
      return getters['conversation/getEarliestMessage'];
    },
    $el: { scrollTop: 0, scrollHeight: 1000 },
    fetchOldConversations: payload =>
      store.dispatch('conversation/fetchOldConversations', payload),
  });
  return flushPromises();
};

const identifyVisitor = async store => {
  await store.dispatch('contacts/setUser', {
    identifier: 'returning-visitor',
    user: { email: 'visitor@example.com', identifier_hash: 'hash' },
  });
  await flushPromises();
};

describe('ConversationWrap history after visitor identification', () => {
  let store;
  let pages;

  beforeEach(() => {
    vi.clearAllMocks();
    store = buildStore();
    pages = [];
    API.patch.mockResolvedValue({ data: {} });
    API.get.mockImplementation(url =>
      Promise.resolve(url === MESSAGES_URL ? page(pages.shift()) : { data: {} })
    );
  });

  it('loads older history for an identified visitor after anonymous history was exhausted', async () => {
    pages = [[], messagesBetween(6, 25), messagesBetween(1, 5)];
    await store.dispatch('conversation/fetchOldConversations', {});
    expect(store.getters['conversation/getAllMessagesLoaded']).toBe(true);

    await identifyVisitor(store);
    expect(store.getters['conversation/getConversationSize']).toBe(20);
    expect(store.getters['conversation/getAllMessagesLoaded']).toBe(false);

    await scrollToTop(store);
    expect(messageRequests()[2]).toEqual([
      MESSAGES_URL,
      { params: { before: 6, after: undefined } },
    ]);
    expect(store.getters['conversation/getConversationSize']).toBe(25);
  });

  it('loads older history when anonymous history was not exhausted', async () => {
    pages = [messagesBetween(30, 31), messagesBetween(6, 25)];
    await store.dispatch('conversation/fetchOldConversations', {});

    await identifyVisitor(store);
    await scrollToTop(store);

    expect(messageRequests()[2]).toEqual([
      MESSAGES_URL,
      { params: { before: 6, after: undefined } },
    ]);
  });

  it('keeps an empty identified history exhausted without requesting more', async () => {
    pages = [[], []];
    await store.dispatch('conversation/fetchOldConversations', {});

    await identifyVisitor(store);
    await scrollToTop(store);

    expect(store.getters['conversation/getAllMessagesLoaded']).toBe(true);
    expect(messageRequests()).toHaveLength(2);
  });
});
