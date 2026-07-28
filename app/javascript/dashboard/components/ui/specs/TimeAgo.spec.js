import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';
import TimeAgo from '../TimeAgo.vue';

// Every instant below is built with the local-time Date constructor rather than
// a fixed UTC offset, so the calendar boundaries land the same way in whatever
// timezone the suite runs in. Writing process.env.TZ here would not work: Node
// resolves the zone once at startup and ignores later assignment.
const at = (...parts) => new Date(...parts);
const toUnix = date => date.getTime() / 1000;

const mountTimeAgo = props =>
  mount(TimeAgo, {
    props,
    global: {
      mocks: {
        $t: key =>
          key === 'CHAT_LIST.TIME_BUCKETS.YESTERDAY' ? 'Yesterday' : key,
      },
    },
  });

describe('TimeAgo calendar timestamp', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('renders the calendar label beside relative time when requested', () => {
    vi.setSystemTime(at(2026, 6, 27, 0, 15));
    const wrapper = mountTimeAgo({
      isAutoRefreshEnabled: false,
      conversationId: 1,
      lastActivityTimestamp: toUnix(at(2026, 6, 27, 0, 10)),
      createdAtTimestamp: toUnix(at(2026, 6, 20, 12)),
      displayTimestamp: toUnix(at(2026, 6, 26, 23, 45)),
      showCalendarTimestamp: true,
    });

    expect(wrapper.text()).toBe('Yesterday • 30m');
  });

  it('refreshes the calendar label when the day rolls over while the list is open', async () => {
    vi.setSystemTime(at(2026, 6, 27, 23, 59, 30));
    const wrapper = mountTimeAgo({
      conversationId: 1,
      lastActivityTimestamp: toUnix(at(2026, 6, 27, 23, 45)),
      createdAtTimestamp: toUnix(at(2026, 6, 20, 12)),
      displayTimestamp: toUnix(at(2026, 6, 27, 23, 45)),
      showCalendarTimestamp: true,
    });

    expect(wrapper.text()).not.toContain('Yesterday');

    // The refresh timer must not be allowed to sleep past local midnight, so a
    // tick shorter than its usual tier has to land just after the boundary.
    vi.advanceTimersByTime(35 * 1000);
    await nextTick();

    expect(wrapper.text()).toContain('Yesterday');
  });
});
