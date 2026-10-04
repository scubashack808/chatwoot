import { nextTick, ref } from 'vue';
import { createStore } from 'vuex';
import { flushPromises, shallowMount } from '@vue/test-utils';
import Copilot from 'dashboard/components-next/copilot/Copilot.vue';
import CopilotInput from 'dashboard/components-next/copilot/CopilotInput.vue';
import ToggleAssistant from 'dashboard/components-next/copilot/ToggleCopilotAssistant.vue';
import threads from 'dashboard/store/captain/copilotThreads';
import messages from 'dashboard/store/captain/copilotMessages';
import CopilotContainer from './CopilotContainer.vue';

const preferences = vi.hoisted(() => ({ settings: null }));
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));
vi.mock('dashboard/composables/useConfig', () => ({
  useConfig: () => ({ isEnterprise: true }),
}));
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    uiSettings: preferences.settings,
    updateUISettings: update =>
      Object.assign(preferences.settings.value, update),
  }),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const assistants = [
  { id: 1, name: 'Assistant A' },
  { id: 2, name: 'Assistant B' },
];
let wrapper;
let store;
let http;

beforeEach(() => {
  preferences.settings = ref({
    is_copilot_panel_open: true,
    preferred_captain_assistant_id: 1,
  });
  http = {
    post: vi.fn().mockImplementation(async (url, data) => ({
      data: url.endsWith('/copilot_messages')
        ? {
            id: 501,
            copilot_thread: { id: Number(url.split('/').at(-2)) },
            message_type: 'user',
            message: { content: data.message },
          }
        : { id: data.assistant_id === 1 ? 101 : 202 },
    })),
  };
  vi.stubGlobal('axios', http);
  store = createStore({
    state: { chat: { id: 10 }, inboxAssistant: assistants[0] },
    getters: {
      getSelectedChat: state => state.chat,
      getCurrentUser: () => ({ id: 7 }),
      getCurrentAccountId: () => 1,
      getCopilotAssistant: state => state.inboxAssistant,
      getLastEmailInSelectedChat: () => null,
      'accounts/isFeatureEnabledonAccount': () => () => true,
      'captainAssistants/getRecords': () => assistants,
      'captainAssistants/getUIFlags': () => ({ fetchingList: false }),
    },
    actions: { 'captainAssistants/get': vi.fn() },
    modules: {
      copilotThreads: {
        ...threads,
        state: JSON.parse(JSON.stringify(threads.state)),
      },
      copilotMessages: {
        ...messages,
        state: JSON.parse(JSON.stringify(messages.state)),
      },
    },
  });
  wrapper = shallowMount(CopilotContainer, {
    props: { conversationInboxType: 'Channel::Email' },
    global: {
      plugins: [store],
      mocks: { $t: key => key },
      stubs: { Copilot: false, CopilotInput: false },
    },
  });
});

afterEach(() => {
  wrapper.unmount();
  vi.unstubAllGlobals();
});

const send = async text => {
  const input = wrapper.findComponent(CopilotInput);
  await input.find('textarea').setValue(text);
  await input.find('form').trigger('submit');
  await flushPromises();
};

const choose = assistant => {
  wrapper.findComponent(ToggleAssistant).vm.$emit('setAssistant', assistant);
};

describe('CopilotContainer request routing', () => {
  it('creates a B thread after switching and reuses only that thread', async () => {
    await send('A question');
    expect(http.post).toHaveBeenLastCalledWith(
      expect.stringMatching(/\/copilot_threads$/),
      expect.objectContaining({ assistant_id: 1, conversation_id: 10 })
    );
    await store.dispatch('copilotMessages/upsert', {
      id: 100,
      copilot_thread: { id: 101 },
      message_type: 'assistant',
      message: { content: 'A reply' },
    });
    expect(wrapper.findComponent(Copilot).props('messages')).toHaveLength(1);

    choose(assistants[1]);
    await nextTick();
    expect(wrapper.findComponent(Copilot).props('activeAssistant').id).toBe(2);
    expect(wrapper.findComponent(Copilot).props('messages')).toEqual([]);
    await send('B question');
    expect(http.post).toHaveBeenLastCalledWith(
      expect.stringMatching(/\/copilot_threads$/),
      expect.objectContaining({ assistant_id: 2, message: 'B question' })
    );
    await send('B follow-up');
    expect(http.post).toHaveBeenLastCalledWith(
      expect.stringMatching(/\/202\/copilot_messages$/),
      expect.objectContaining({ assistant_id: 2, message: 'B follow-up' })
    );
  });

  it('selects B before the first prompt', async () => {
    choose(assistants[1]);
    await send('B question');
    expect(http.post).toHaveBeenLastCalledWith(
      expect.stringMatching(/\/copilot_threads$/),
      expect.objectContaining({ assistant_id: 2 })
    );
  });

  it('preserves the thread when selecting the same assistant', async () => {
    await send('A question');
    choose(assistants[0]);
    await send('A follow-up');
    expect(http.post).toHaveBeenLastCalledWith(
      expect.stringMatching(/\/101\/copilot_messages$/),
      expect.objectContaining({ assistant_id: 1 })
    );
  });

  it.each(['conversation', 'reset', 'preference', 'inbox'])(
    'starts a fresh thread after a %s change',
    async change => {
      if (change === 'inbox') {
        preferences.settings.value.preferred_captain_assistant_id = null;
      }
      await send('First question');
      if (change === 'conversation') store.state.chat = { id: 11 };
      if (change === 'reset') wrapper.findComponent(Copilot).vm.$emit('reset');
      if (change === 'preference') {
        preferences.settings.value.preferred_captain_assistant_id = 2;
      }
      if (change === 'inbox') store.state.inboxAssistant = assistants[1];

      // Send in the same tick, before a batched watcher would invalidate the thread.
      wrapper.findComponent(Copilot).vm.$emit('sendMessage', 'Next question');
      await flushPromises();
      expect(http.post).toHaveBeenLastCalledWith(
        expect.stringMatching(/\/copilot_threads$/),
        expect.objectContaining({
          assistant_id: ['preference', 'inbox'].includes(change) ? 2 : 1,
          conversation_id: change === 'conversation' ? 11 : 10,
        })
      );
    }
  );

  it.each([
    'assistant',
    'assistant round trip',
    'reset',
    'conversation',
    'conversation round trip',
  ])('ignores a pending thread response after %s changes', async change => {
    let resolveRequest;
    http.post.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveRequest = resolve;
        })
    );
    await send('Delayed A question');
    if (change.startsWith('assistant')) {
      choose(assistants[1]);
      if (change === 'assistant round trip') choose(assistants[0]);
    }
    if (change === 'reset') wrapper.findComponent(Copilot).vm.$emit('reset');
    if (change.startsWith('conversation')) {
      store.state.chat = { id: 11 };
      if (change === 'conversation round trip') store.state.chat = { id: 10 };
    }
    resolveRequest({ data: { id: 999 } });
    await flushPromises();
    await send('Current question');
    expect(http.post).toHaveBeenLastCalledWith(
      expect.stringMatching(/\/copilot_threads$/),
      expect.objectContaining({ message: 'Current question' })
    );
  });

  it('does not replace an established B thread with a late A response', async () => {
    let resolveRequest;
    http.post.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveRequest = resolve;
        })
    );
    await send('Delayed A question');
    choose(assistants[1]);
    await send('B question');
    resolveRequest({ data: { id: 101 } });
    await flushPromises();
    await send('B follow-up');
    expect(http.post).toHaveBeenLastCalledWith(
      expect.stringMatching(/\/202\/copilot_messages$/),
      expect.objectContaining({ assistant_id: 2 })
    );
  });
});
