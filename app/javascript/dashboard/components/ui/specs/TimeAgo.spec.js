import { mount } from '@vue/test-utils';
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
