import { ref } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { emitter } from 'shared/helpers/mitt';
import { CMD_SNOOZE_CONVERSATION } from 'dashboard/helper/commandbar/events';
import { getUnixTime } from 'date-fns';
import CommandBar from '../commandbar.vue';
import CmdBarConversationSnooze from '../CmdBarConversationSnooze.vue';

// The defect this file guards lives in the seam between the two components:
// the command bar decides whether to clear the context id, the snooze
// component reads it. Each component's own spec mocks the other side, so
// both can pass while the user-facing behaviour is broken. Here they share
// one real store.

vi.mock('@chatwoot/ninja-keys', () => ({}));
vi.mock('dashboard/composables', () => ({
  useTrack: vi.fn(),
  useAlert: vi.fn(),
}));

const noopHotKeys = {
  useAppearanceHotKeys: () => ({ goToAppearanceHotKeys: ref([]) }),
  useInboxHotKeys: () => ({ inboxHotKeys: ref([]) }),
  useGoToCommandHotKeys: () => ({ goToCommandHotKeys: ref([]) }),
  useBulkActionsHotKeys: () => ({ bulkActionsHotKeys: ref([]) }),
  useConversationHotKeys: () => ({ conversationHotKeys: ref([]) }),
};

vi.mock('dashboard/composables/commands/useAppearanceHotKeys', () => ({
  useAppearanceHotKeys: () => noopHotKeys.useAppearanceHotKeys(),
}));
vi.mock('dashboard/composables/commands/useInboxHotKeys', () => ({
  useInboxHotKeys: () => noopHotKeys.useInboxHotKeys(),
}));
vi.mock('dashboard/composables/commands/useGoToCommandHotKeys', () => ({
  useGoToCommandHotKeys: () => noopHotKeys.useGoToCommandHotKeys(),
}));
vi.mock('dashboard/composables/commands/useBulkActionsHotKeys', () => ({
  useBulkActionsHotKeys: () => noopHotKeys.useBulkActionsHotKeys(),
}));
vi.mock('dashboard/composables/commands/useConversationHotKeys', () => ({
  useConversationHotKeys: () => noopHotKeys.useConversationHotKeys(),
}));
vi.mock('dashboard/composables/commands/useMacroHotKeys', () => ({
  useMacroHotKeys: () => ({
    macroHotKeys: ref([]),
    pendingAttributes: ref(null),
    submitPendingAttributes: vi.fn(),
    dismissPendingAttributes: vi.fn(),
  }),
}));

class NinjaKeysSeamStub extends HTMLElement {
  open(options = {}) {
    this.openedWith = options;
  }

  // Faithful to node_modules/@chatwoot/ninja-keys/dist/ninja-keys.js.
  close() {
    this.dispatchEvent(new CustomEvent('closed', { bubbles: true }));
  }
}
customElements.define('ninja-keys', NinjaKeysSeamStub);

const CONV_A = 1; // open in the detail pane
const CONV_B = 2; // the card that was right-clicked

describe('snooze context routing across the command bar seam', () => {
  let store;
  let toggleStatus;
  let bar;
  let snooze;

  beforeEach(async () => {
    toggleStatus = vi.fn().mockResolvedValue({});
    store = createStore({
      state: {
        allConversations: [{ id: CONV_A }, { id: CONV_B }],
        selectedChatId: CONV_A,
        contextMenuChatId: null,
      },
      mutations: {
        SET_CONTEXT_MENU_CHAT_ID: (state, id) => {
          state.contextMenuChatId = id;
        },
      },
      getters: {
        getSelectedChat: state =>
          state.allConversations.find(c => c.id === state.selectedChatId) || {},
        getContextMenuChatId: state => state.contextMenuChatId,
      },
      actions: {
        toggleStatus,
        setContextMenuChatId: ({ commit }, id) =>
          commit('SET_CONTEXT_MENU_CHAT_ID', id),
      },
    });

    bar = mount(CommandBar, {
      global: {
        plugins: [store],
        stubs: {
          ConversationResolveAttributesModal: true,
          'ninja-keys': false,
        },
      },
    });
    snooze = mount(CmdBarConversationSnooze, {
      global: {
        plugins: [store],
        mocks: { $t: key => key },
        stubs: { 'woot-modal': true, CustomSnoozeModal: true },
      },
    });
    await flushPromises();
  });

  afterEach(() => {
    bar?.unmount();
    snooze?.unmount();
  });

  // Right-click card B while A is open, as contextMenu/Index.vue does.
  const openContextMenuOnB = async () => {
    await store.dispatch('setContextMenuChatId', CONV_B);
    bar.find('ninja-keys').element.open({ parent: 'snooze_conversation' });
    await flushPromises();
  };

  const selectCommand = async id => {
    bar
      .find('ninja-keys')
      .element.dispatchEvent(
        new CustomEvent('selected', { detail: { action: { id } } })
      );
    await flushPromises();
  };

  // ninja-keys closes itself once an action handler has run.
  const barClosesItself = async () => {
    bar.find('ninja-keys').element.close();
    await flushPromises();
  };

  const target = () => toggleStatus.mock.calls[0][1].conversationId;

  it('routes a custom-date snooze to the right-clicked card', async () => {
    await openContextMenuOnB();
    await selectCommand('until_custom_time');
    emitter.emit(CMD_SNOOZE_CONVERSATION, 'until_custom_time');
    await barClosesItself();

    const chosen = new Date('2030-01-01T10:00:00Z');
    snooze
      .findComponent({ name: 'CustomSnoozeModal' })
      .vm.$emit('chooseTime', chosen);
    await flushPromises();

    expect(toggleStatus).toHaveBeenCalledTimes(1);
    expect(target()).toBe(CONV_B);
    expect(toggleStatus.mock.calls[0][1].snoozedUntil).toBe(
      getUnixTime(chosen)
    );
  });

  it('routes a preset snooze to the right-clicked card', async () => {
    await openContextMenuOnB();
    await selectCommand('until_tomorrow');
    emitter.emit(CMD_SNOOZE_CONVERSATION, 2000000000);
    await barClosesItself();
    await flushPromises();

    expect(target()).toBe(CONV_B);
  });

  it('snoozes the open conversation when the bar was not opened from a card', async () => {
    bar.find('ninja-keys').element.open({ parent: 'snooze_conversation' });
    await selectCommand('until_custom_time');
    emitter.emit(CMD_SNOOZE_CONVERSATION, 'until_custom_time');
    await barClosesItself();

    snooze
      .findComponent({ name: 'CustomSnoozeModal' })
      .vm.$emit('chooseTime', new Date('2030-01-01T10:00:00Z'));
    await flushPromises();

    expect(target()).toBe(CONV_A);
  });
});
