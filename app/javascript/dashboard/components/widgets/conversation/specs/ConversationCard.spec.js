import { shallowMount } from '@vue/test-utils';
import ConversationCard from '../ConversationCard.vue';

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

const mountComponent = (chat, currentContact = {}, props = {}) =>
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
      ...props,
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

const listProps = { showRepliedMarker: true, showCalendarTimestamp: true };

const repliedChat = {
  last_public_incoming_message: { id: 10, created_at: 1700000100 },
  last_agent_reply_message: { id: 11, created_at: 1700000200 },
};

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

  it('carries the conversation class the list seam rule targets', () => {
    expect(mountComponent({}).classes()).toContain('conversation');
  });

  describe('when the list opts into the new presentation', () => {
    it('shows the replied marker when a successful reply is newer than the newest incoming', () => {
      const wrapper = mountComponent(
        { waiting_since: 1700000100, ...repliedChat },
        {},
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
        {},
        listProps
      );

      expect(wrapper.find('[data-testid="replied-marker"]').exists()).toBe(
        false
      );
    });

    it('ignores newer private and activity messages when rendering the marker', () => {
      const wrapper = mountComponent(
        {
          messages: [
            { id: 13, message_type: 0, created_at: 1700000300, private: true },
            { id: 14, message_type: 2, created_at: 1700000400 },
          ],
          ...repliedChat,
        },
        {},
        listProps
      );

      expect(wrapper.find('[data-testid="replied-marker"]').exists()).toBe(
        true
      );
    });

    it('widens the reserved name padding for the marker and calendar column', () => {
      const wrapper = mountComponent({}, {}, listProps);

      expect(wrapper.find('h4.conversation--user').classes()).toContain(
        'ltr:pr-28'
      );
    });
  });

  describe('by default, for consumers such as the contact sidebar', () => {
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

    it('keeps the narrower reserved name padding', () => {
      const classes = mountComponent({})
        .find('h4.conversation--user')
        .classes();

      expect(classes).toContain('ltr:pr-16');
      expect(classes).not.toContain('ltr:pr-28');
    });
  });
});
