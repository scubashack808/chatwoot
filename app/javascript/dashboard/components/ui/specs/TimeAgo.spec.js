import { mount } from '@vue/test-utils';
import { nextTick } from 'vue';
import TimeAgo from '../TimeAgo.vue';

const originalTimezone = process.env.TZ;
const toTimestamp = value => new Date(value).getTime() / 1000;

describe('TimeAgo calendar timestamp', () => {
  beforeAll(() => {
    process.env.TZ = 'Pacific/Honolulu';
  });

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-07-27T00:15:00-10:00'));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  afterAll(() => {
    process.env.TZ = originalTimezone;
  });

  it('renders the HST calendar label beside relative time when requested', () => {
    const displayTimestamp = toTimestamp('2026-07-26T23:45:00-10:00');
    const wrapper = mount(TimeAgo, {
      props: {
        isAutoRefreshEnabled: false,
        conversationId: 1,
        lastActivityTimestamp: toTimestamp('2026-07-27T00:10:00-10:00'),
        createdAtTimestamp: toTimestamp('2026-07-20T12:00:00-10:00'),
        displayTimestamp,
        showCalendarTimestamp: true,
      },
      global: {
        mocks: {
          $t: key =>
            key === 'CHAT_LIST.TIME_BUCKETS.YESTERDAY' ? 'Yesterday' : key,
        },
      },
    });

    expect(wrapper.text()).toBe('Yesterday • 30m');
  });
});

// Built with the local-time Date constructor so the midnight boundary is real
// in whatever timezone the suite runs in.
describe('TimeAgo calendar timestamp across local midnight', () => {
  const at = (...parts) => new Date(...parts);
  const toUnix = date => date.getTime() / 1000;

  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('refreshes the calendar label when the day rolls over while the list is open', async () => {
    vi.setSystemTime(at(2026, 6, 27, 23, 59, 30));
    const wrapper = mount(TimeAgo, {
      props: {
        conversationId: 1,
        lastActivityTimestamp: toUnix(at(2026, 6, 27, 23, 45)),
        createdAtTimestamp: toUnix(at(2026, 6, 20, 12)),
        displayTimestamp: toUnix(at(2026, 6, 27, 23, 45)),
        showCalendarTimestamp: true,
      },
      global: {
        mocks: {
          $t: key =>
            key === 'CHAT_LIST.TIME_BUCKETS.YESTERDAY' ? 'Yesterday' : key,
        },
      },
    });

    expect(wrapper.text()).not.toContain('Yesterday');

    // The refresh timer must not be allowed to sleep past local midnight, so a
    // tick shorter than its usual tier has to land just after the boundary.
    vi.advanceTimersByTime(35 * 1000);
    await nextTick();

    expect(wrapper.text()).toContain('Yesterday');
  });
});
