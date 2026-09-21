import { mount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import { emitter } from 'shared/helpers/mitt';
import { CMD_SNOOZE_CONVERSATION } from 'dashboard/helper/commandbar/events';
import { getUnixTime } from 'date-fns';
import CmdBarConversationSnooze from '../CmdBarConversationSnooze.vue';

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));

const CONV_A = 1; // the conversation open in the detail pane
const CONV_B = 2; // the card whose context menu was opened

const toggleStatus = vi.fn();
const setContextMenuChatId = vi.fn();

const buildStore = ({ selectedChatId, contextMenuChatId }) =>
  createStore({
    state: {
      allConversations: [
        { id: CONV_A, status: 'open' },
        { id: CONV_B, status: 'open' },
      ],
      selectedChatId,
      contextMenuChatId,
    },
    getters: {
      getSelectedChat: state =>
        state.allConversations.find(c => c.id === state.selectedChatId) || {},
      getContextMenuChatId: state => state.contextMenuChatId,
    },
    actions: { toggleStatus, setContextMenuChatId },
  });

describe('CmdBarConversationSnooze', () => {
  let wrapper;

  const mountWith = ({ selectedChatId, contextMenuChatId }) => {
    wrapper = mount(CmdBarConversationSnooze, {
      global: {
        plugins: [buildStore({ selectedChatId, contextMenuChatId })],
        mocks: { $t: key => key },
        stubs: { 'woot-modal': true, CustomSnoozeModal: true },
      },
    });
    return wrapper;
  };

  const snoozedConversationId = () =>
    toggleStatus.mock.calls[0][1].conversationId;

  beforeEach(() => {
    toggleStatus.mockClear();
    setContextMenuChatId.mockClear();
  });

  afterEach(() => {
    // useEmitter binds the listener on mount, so an un-unmounted component from
    // a previous test keeps answering the event and pollutes the call list.
    wrapper?.unmount();
    wrapper = undefined;
  });

  describe('when a card context menu targets a different conversation', () => {
    it('applies a preset snooze to the context menu conversation', async () => {
      mountWith({ selectedChatId: CONV_A, contextMenuChatId: CONV_B });

      emitter.emit(CMD_SNOOZE_CONVERSATION, 'until_next_reply');
      await flushPromises();

      expect(toggleStatus).toHaveBeenCalledTimes(1);
      expect(snoozedConversationId()).toBe(CONV_B);
    });

    it('applies a numeric snooze to the context menu conversation', async () => {
      mountWith({ selectedChatId: CONV_A, contextMenuChatId: CONV_B });

      emitter.emit(CMD_SNOOZE_CONVERSATION, 2000000000);
      await flushPromises();

      expect(snoozedConversationId()).toBe(CONV_B);
    });

    it('applies a custom date snooze to the context menu conversation', async () => {
      mountWith({ selectedChatId: CONV_A, contextMenuChatId: CONV_B });
      const customTime = new Date('2030-01-01T10:00:00Z');

      emitter.emit(CMD_SNOOZE_CONVERSATION, 'until_custom_time');
      await flushPromises();
      wrapper
        .findComponent({ name: 'CustomSnoozeModal' })
        .vm.$emit('chooseTime', customTime);
      await flushPromises();

      expect(snoozedConversationId()).toBe(CONV_B);
      expect(toggleStatus.mock.calls[0][1].snoozedUntil).toBe(
        getUnixTime(customTime)
      );
    });

    it('clears the context menu conversation once the snooze is applied', async () => {
      mountWith({ selectedChatId: CONV_A, contextMenuChatId: CONV_B });

      emitter.emit(CMD_SNOOZE_CONVERSATION, 2000000000);
      await flushPromises();

      expect(setContextMenuChatId).toHaveBeenCalledTimes(1);
      expect(setContextMenuChatId.mock.calls[0][1]).toBeNull();
    });
  });

  it('snoozes the open conversation when no context menu is involved', async () => {
    mountWith({ selectedChatId: CONV_A, contextMenuChatId: null });

    emitter.emit(CMD_SNOOZE_CONVERSATION, 2000000000);
    await flushPromises();

    expect(snoozedConversationId()).toBe(CONV_A);
  });

  it('snoozes the context menu conversation when none is open', async () => {
    mountWith({ selectedChatId: null, contextMenuChatId: CONV_B });

    emitter.emit(CMD_SNOOZE_CONVERSATION, 2000000000);
    await flushPromises();

    expect(snoozedConversationId()).toBe(CONV_B);
  });
});
