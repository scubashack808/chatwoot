import { shallowMount } from '@vue/test-utils';
import ConversationCardExpanded from '../ConversationCardExpanded.vue';

const defaultChat = {
  id: 1,
  labels: [],
  messages: [],
  last_public_non_activity_message: null,
  priority: null,
  unread_count: 0,
  timestamp: 1700000000,
  created_at: 1700000000,
};

const mountComponent = chat =>
  shallowMount(ConversationCardExpanded, {
    props: {
      chat: { ...defaultChat, ...chat },
      currentContact: {
        name: 'Jane Doe',
        thumbnail: '',
        availability_status: 'offline',
      },
      inbox: { id: 1 },
    },
    global: {
      mocks: {
        $t: key => key,
      },
    },
  });

describe('ConversationCardExpanded', () => {
  it('shows the replied marker when the latest public non-activity message is outgoing', () => {
    const wrapper = mountComponent({
      waiting_since: 1700000100,
      last_public_non_activity_message: {
        message_type: 1,
        created_at: 1700000200,
      },
    });

    expect(wrapper.find('[data-testid="replied-marker"]').exists()).toBe(true);
  });

  it('does not infer the replied marker from a blank waiting_since', () => {
    const wrapper = mountComponent({
      waiting_since: null,
      last_public_non_activity_message: {
        message_type: 0,
        created_at: 1700000200,
      },
    });

    expect(wrapper.find('[data-testid="replied-marker"]').exists()).toBe(false);
  });
});
