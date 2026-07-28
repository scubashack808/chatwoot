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

// Every instant below is built with the local-time Date constructor rather than
// a fixed UTC offset, so calendar boundaries land the same way in whatever
// timezone the suite runs in. Writing process.env.TZ here would not work: Node
// resolves the zone once at startup and ignores later assignment.
const at = (...parts) => new Date(...parts);

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
  // Typed rather than declared as a name list so a valueless boolean attribute
  // resolves to true here exactly as it does on the real component.
  props: {
    source: { type: Object, default: () => ({}) },
    displayTimestamp: { type: [String, Number], default: '' },
    showRepliedMarker: { type: Boolean, default: false },
    showCalendarTimestamp: { type: Boolean, default: false },
  },
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
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(at(2026, 6, 27, 12, 0, 0));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('renders calendar buckets from the last-activity sort timestamp', () => {
    const wrapper = mountComponent({
      conversationList: [
        conversation({ id: 1, lastActivityAt: at(2026, 6, 27, 9, 30) }),
        conversation({ id: 2, lastActivityAt: at(2026, 6, 26, 23, 30) }),
        conversation({ id: 3, lastActivityAt: at(2026, 6, 23, 12) }),
        conversation({ id: 4, lastActivityAt: at(2026, 6, 10, 12) }),
        conversation({ id: 5, lastActivityAt: at(2026, 5, 20, 12) }),
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
        createdAt: at(2026, 6, 27, 8),
        lastActivityAt: at(2026, 5, 1, 8),
      }),
      conversation({
        id: 3,
        createdAt: at(2026, 6, 26, 23),
        lastActivityAt: at(2026, 6, 27, 11),
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
        conversation({ id: 41, lastActivityAt: at(2026, 6, 26, 12) }),
        conversation({ id: 7, lastActivityAt: at(2026, 6, 27, 11) }),
        conversation({ id: 29, lastActivityAt: at(2026, 6, 10, 12) }),
      ],
    });

    expect(renderedConversationIds(wrapper)).toEqual([41, 7, 29]);
  });

  it('does not duplicate a bucket header when another page continues that bucket', async () => {
    const firstPage = [
      conversation({ id: 1, lastActivityAt: at(2026, 6, 27, 11) }),
    ];
    const wrapper = mountComponent({ conversationList: firstPage });

    await wrapper.setProps({
      conversationList: [
        ...firstPage,
        conversation({ id: 2, lastActivityAt: at(2026, 6, 27, 10) }),
        conversation({ id: 3, lastActivityAt: at(2026, 6, 26, 22) }),
      ],
    });

    expect(renderedConversationIds(wrapper)).toEqual([1, 2, 3]);
    expect(renderedBucketLabels(wrapper)).toEqual(['Today', 'Yesterday']);
  });

  it('renders the plain server sequence for a non-chronological sort', () => {
    const wrapper = mountComponent({
      conversationList: [
        conversation({ id: 12, lastActivityAt: at(2026, 6, 10, 12) }),
        conversation({ id: 4, lastActivityAt: at(2026, 6, 27, 11) }),
      ],
      sortBy: 'waiting_since_desc',
    });

    expect(renderedConversationIds(wrapper)).toEqual([12, 4]);
    expect(renderedBucketLabels(wrapper)).toEqual([]);
  });

  it('opts the rendered cards into the list-only presentation', () => {
    const wrapper = mountComponent({
      conversationList: [
        conversation({ id: 1, lastActivityAt: at(2026, 6, 27, 11) }),
      ],
    });
    const item = wrapper.findComponent({ name: 'ConversationItem' });

    expect(item.props('showRepliedMarker')).toBe(true);
    expect(item.props('showCalendarTimestamp')).toBe(true);
  });
});

describe('ConversationList wall clock handling', () => {
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
