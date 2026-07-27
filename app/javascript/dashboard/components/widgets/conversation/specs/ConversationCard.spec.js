import { shallowMount } from '@vue/test-utils';
import ConversationCard from '../ConversationCard.vue';

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

const mountComponent = (chat, currentContact = {}) =>
  shallowMount(ConversationCard, {
    props: {
      chat: { ...defaultChat, ...chat },
      currentContact: {
        name: 'Jane Doe',
        thumbnail: '',
        availability_status: 'offline',
        ...currentContact,
      },
      inbox: { id: 1 },
    },
    global: {
      mocks: {
        $t: key => key,
      },
      stubs: {
        'fluent-icon': true,
      },
    },
  });

describe('ConversationCard', () => {
  it('does not reserve the labels row when only a persisted SLA policy id is present', () => {
    const wrapper = mountComponent({ sla_policy_id: 1, applied_sla: null });

    expect(wrapper.findComponent({ name: 'CardLabels' }).exists()).toBe(false);
  });

  it('shows the labels row when an active applied SLA is present', () => {
    const wrapper = mountComponent({
      sla_policy_id: 1,
      applied_sla: { id: 1 },
    });

    expect(wrapper.findComponent({ name: 'CardLabels' }).exists()).toBe(true);
  });

  it('does not reserve the labels row when the contact is blocked', () => {
    const wrapper = mountComponent(
      {
        sla_policy_id: 1,
        applied_sla: { id: 1 },
      },
      { blocked: true }
    );

    expect(wrapper.findComponent({ name: 'CardLabels' }).exists()).toBe(false);
  });

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

  it('ignores newer private and activity messages when rendering the replied marker', () => {
    const wrapper = mountComponent({
      messages: [
        {
          message_type: 0,
          created_at: 1700000100,
          private: true,
        },
        {
          message_type: 2,
          created_at: 1700000300,
          private: false,
        },
      ],
      last_public_non_activity_message: {
        message_type: 1,
        created_at: 1700000000,
      },
    });

    expect(wrapper.find('[data-testid="replied-marker"]').exists()).toBe(true);
  });
});
