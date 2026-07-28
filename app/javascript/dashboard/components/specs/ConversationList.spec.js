import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';
import ConversationList from '../ConversationList.vue';

vi.mock('virtua/vue', () => ({
  Virtualizer: {
    props: ['data'],
    template: `
      <div data-testid="virtualizer">
        <template v-for="item in data">
          <slot :item="item" />
        </template>
      </div>
    `,
  },
}));

vi.mock('../ConversationItem.vue', () => ({
  default: {
    name: 'ConversationItem',
    template: '<div />',
  },
}));

vi.mock('dashboard/composables/chatlist/useChatListKeyboardEvents', () => ({
  useChatListKeyboardEvents: vi.fn(),
}));

const originalTimezone = process.env.TZ;

const translations = {
  'CHAT_LIST.TIME_BUCKETS.TODAY': 'Today',
  'CHAT_LIST.TIME_BUCKETS.YESTERDAY': 'Yesterday',
  'CHAT_LIST.TIME_BUCKETS.THIS_WEEK': 'This Week',
  'CHAT_LIST.TIME_BUCKETS.THIS_MONTH': 'This Month',
  'CHAT_LIST.TIME_BUCKETS.OLDER': 'Older',
};

const toTimestamp = value => new Date(value).getTime() / 1000;

const conversation = ({ id, lastActivityAt, createdAt = lastActivityAt }) => ({
  id,
  last_activity_at: toTimestamp(lastActivityAt),
  timestamp: toTimestamp(lastActivityAt),
  created_at: toTimestamp(createdAt),
});

const ConversationItemStub = {
  name: 'ConversationItem',
  props: [
    'source',
    'displayTimestamp',
    'showRepliedMarker',
    'showCalendarTimestamp',
  ],
  template: `
    <div
      data-testid="conversation-card"
      :data-conversation-id="source.id"
      :data-display-timestamp="displayTimestamp"
    />
  `,
};

const mountComponent = ({
  conversationList,
  sortBy = 'last_activity_at_desc',
}) =>
  mount(ConversationList, {
    props: {
      conversationList,
      sortBy,
    },
    global: {
      mocks: {
        $t: key => translations[key] || key,
      },
      stubs: {
        ConversationItem: ConversationItemStub,
        IntersectionObserver: true,
        Spinner: true,
      },
    },
  });

const renderedConversationIds = wrapper =>
  wrapper
    .findAll('[data-testid="conversation-card"]')
    .map(card => Number(card.attributes('data-conversation-id')));

const renderedBucketLabels = wrapper =>
  wrapper
    .findAll('[data-testid="time-bucket-header"]')
    .map(header => header.text());

describe('ConversationList time buckets', () => {
  beforeAll(() => {
    process.env.TZ = 'Pacific/Honolulu';
  });

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-07-27T12:00:00-10:00'));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  afterAll(() => {
    process.env.TZ = originalTimezone;
  });

  it('renders HST calendar buckets from the last-activity sort timestamp', () => {
    const wrapper = mountComponent({
      conversationList: [
        conversation({
          id: 1,
          lastActivityAt: '2026-07-27T09:30:00-10:00',
        }),
        conversation({
          id: 2,
          lastActivityAt: '2026-07-26T23:30:00-10:00',
        }),
        conversation({
          id: 3,
          lastActivityAt: '2026-07-23T12:00:00-10:00',
        }),
        conversation({
          id: 4,
          lastActivityAt: '2026-07-10T12:00:00-10:00',
        }),
        conversation({
          id: 5,
          lastActivityAt: '2026-06-20T12:00:00-10:00',
        }),
      ],
    });
    expect(renderedBucketLabels(wrapper)).toEqual([
      'Today',
      'Yesterday',
      'This Week',
      'This Month',
      'Older',
    ]);
  });

  it('uses created_at for both headers and displayed dates under created_at_desc', () => {
    const conversations = [
      conversation({
        id: 8,
        createdAt: '2026-07-27T08:00:00-10:00',
        lastActivityAt: '2026-06-01T08:00:00-10:00',
      }),
      conversation({
        id: 3,
        createdAt: '2026-07-26T23:00:00-10:00',
        lastActivityAt: '2026-07-27T11:00:00-10:00',
      }),
    ];
    const wrapper = mountComponent({
      conversationList: conversations,
      sortBy: 'created_at_desc',
    });

    expect(renderedConversationIds(wrapper)).toEqual([8, 3]);
    expect(renderedBucketLabels(wrapper)).toEqual(['Today', 'Yesterday']);
    expect(
      wrapper
        .findAll('[data-testid="conversation-card"]')
        .map(card => Number(card.attributes('data-display-timestamp')))
    ).toEqual(conversations.map(item => item.created_at));
  });

  it('keeps the supplied server order even when timestamps are non-monotonic', () => {
    const wrapper = mountComponent({
      conversationList: [
        conversation({
          id: 41,
          lastActivityAt: '2026-07-26T12:00:00-10:00',
        }),
        conversation({
          id: 7,
          lastActivityAt: '2026-07-27T11:00:00-10:00',
        }),
        conversation({
          id: 29,
          lastActivityAt: '2026-07-10T12:00:00-10:00',
        }),
      ],
    });

    expect(renderedConversationIds(wrapper)).toEqual([41, 7, 29]);
  });

  it('does not duplicate a bucket header when another page continues that bucket', async () => {
    const firstPage = [
      conversation({
        id: 1,
        lastActivityAt: '2026-07-27T11:00:00-10:00',
      }),
    ];
    const wrapper = mountComponent({ conversationList: firstPage });

    await wrapper.setProps({
      conversationList: [
        ...firstPage,
        conversation({
          id: 2,
          lastActivityAt: '2026-07-27T10:00:00-10:00',
        }),
        conversation({
          id: 3,
          lastActivityAt: '2026-07-26T22:00:00-10:00',
        }),
      ],
    });

    expect(renderedConversationIds(wrapper)).toEqual([1, 2, 3]);
    expect(renderedBucketLabels(wrapper)).toEqual(['Today', 'Yesterday']);
  });

  it('renders the plain server sequence for a non-chronological sort', () => {
    const wrapper = mountComponent({
      conversationList: [
        conversation({
          id: 12,
          lastActivityAt: '2026-07-10T12:00:00-10:00',
        }),
        conversation({
          id: 4,
          lastActivityAt: '2026-07-27T11:00:00-10:00',
        }),
      ],
      sortBy: 'waiting_since_desc',
    });

    expect(renderedConversationIds(wrapper)).toEqual([12, 4]);
    expect(renderedBucketLabels(wrapper)).toEqual([]);
  });

  it('opts the rendered cards into the list-only presentation', () => {
    const wrapper = mountComponent({
      conversationList: [
        conversation({ id: 1, lastActivityAt: '2026-07-27T11:00:00-10:00' }),
      ],
    });
    const item = wrapper.findComponent({ name: 'ConversationItem' });

    expect(item.props('showRepliedMarker')).toBe(true);
    expect(item.props('showCalendarTimestamp')).toBe(true);
  });
});

// These tests build every instant with the local-time Date constructor rather
// than a fixed UTC offset, so a real local-midnight boundary is crossed in
// whatever timezone the suite happens to run in.
describe('ConversationList wall clock handling', () => {
  const at = (...parts) => new Date(...parts);

  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('keeps the active/selected seam rule reachable through the row wrapper', () => {
    vi.setSystemTime(at(2026, 6, 27, 12, 0, 0));
    const wrapper = mountComponent({
      conversationList: [
        conversation({ id: 1, lastActivityAt: at(2026, 6, 27, 11) }),
      ],
    });
    const seamClasses = wrapper
      .find('[data-testid="virtualizer"]')
      .attributes('class');

    // The border lives on the card root, which the row wrapper nests one level
    // deeper, so the rule has to reach it by descent rather than by `> *`.
    expect(seamClasses).toContain('.active)_.conversation]');
    expect(seamClasses).toContain('.selected)_.conversation]');
    expect(seamClasses).not.toContain('>*]');
  });

  it('moves a row out of Today once local midnight passes', async () => {
    vi.setSystemTime(at(2026, 6, 27, 23, 59, 30));
    const wrapper = mountComponent({
      conversationList: [
        conversation({ id: 1, lastActivityAt: at(2026, 6, 27, 23, 45) }),
      ],
    });

    expect(renderedBucketLabels(wrapper)).toEqual(['Today']);

    vi.advanceTimersByTime(60 * 1000);
    await nextTick();

    expect(renderedBucketLabels(wrapper)).toEqual(['Yesterday']);
  });

  it('labels a tomorrow-dated row Today instead of stranding it under This Week', () => {
    vi.setSystemTime(at(2026, 6, 27, 23, 50, 0));
    const wrapper = mountComponent({
      conversationList: [
        conversation({ id: 1, lastActivityAt: at(2026, 6, 28, 0, 30) }),
        conversation({ id: 2, lastActivityAt: at(2026, 6, 27, 23, 0) }),
      ],
    });

    expect(renderedBucketLabels(wrapper)).toEqual(['Today']);
  });
});
