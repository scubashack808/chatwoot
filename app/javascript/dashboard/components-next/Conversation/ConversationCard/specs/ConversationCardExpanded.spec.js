import { shallowMount } from '@vue/test-utils';
import ConversationCardExpanded from '../ConversationCardExpanded.vue';

const defaultChat = {
  id: 1,
  labels: [],
  messages: [],
  last_public_incoming_message: null,
  last_agent_reply_message: null,
  priority: null,
  unread_count: 0,
  timestamp: 1700000000,
  created_at: 1700000000,
};

const mountComponent = (chat, props = {}) =>
  shallowMount(ConversationCardExpanded, {
    props: {
      chat: { ...defaultChat, ...chat },
      currentContact: {
        name: 'Jane Doe',
        thumbnail: '',
        availability_status: 'offline',
      },
      inbox: { id: 1 },
      ...props,
    },
    global: {
      mocks: {
        $t: key => key,
      },
    },
  });

const listProps = { showRepliedMarker: true, showCalendarTimestamp: true };

const repliedChat = {
  last_public_incoming_message: { id: 10, created_at: 1700000100 },
  last_agent_reply_message: { id: 11, created_at: 1700000200 },
};

describe('ConversationCardExpanded', () => {
  it('carries the conversation class the list seam rule targets', () => {
    expect(mountComponent({}).classes()).toContain('conversation');
  });

  describe('when the list opts into the new presentation', () => {
    it('shows the replied marker when a successful reply is newer than the newest incoming', () => {
      const wrapper = mountComponent(
        { waiting_since: 1700000100, ...repliedChat },
        listProps
      );

      expect(wrapper.find('[data-testid="replied-marker"]').exists()).toBe(
        true
      );
    });

    it('does not infer the replied marker from a blank waiting_since', () => {
      const wrapper = mountComponent(
        {
          waiting_since: null,
          last_public_incoming_message: { id: 12, created_at: 1700000200 },
          last_agent_reply_message: null,
        },
        listProps
      );

      expect(wrapper.find('[data-testid="replied-marker"]').exists()).toBe(
        false
      );
    });
  });

  describe('by default, for any consumer that does not opt in', () => {
    it('renders no replied marker even when the payload says replied', () => {
      const wrapper = mountComponent(repliedChat);

      expect(wrapper.find('[data-testid="replied-marker"]').exists()).toBe(
        false
      );
    });

    it('leaves TimeAgo on its created-and-last-activity presentation', () => {
      const wrapper = mountComponent(repliedChat);

      expect(
        wrapper
          .findComponent({ name: 'TimeAgo' })
          .props('showCalendarTimestamp')
      ).toBe(false);
    });
  });
});
