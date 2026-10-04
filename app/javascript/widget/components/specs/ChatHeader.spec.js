import { shallowMount, enableAutoUnmount } from '@vue/test-utils';
import ChatHeader from '../ChatHeader.vue';

vi.mock('vue-router', () => ({
  useRouter: () => ({ replace: vi.fn() }),
}));

enableAutoUnmount(afterEach);

describe('ChatHeader working-hours availability', () => {
  const originalChannel = window.chatwootWebChannel;
  const mountOptions = {
    props: { title: 'Test shop', availableAgents: [{ id: 1 }] },
    global: {
      directives: {
        dompurifyHtml: (element, binding) => {
          element.textContent = binding.value;
        },
      },
    },
  };

  beforeEach(() => {
    vi.useFakeTimers();
    window.chatwootWebChannel = {
      timezone: 'UTC',
      workingHoursEnabled: true,
      workingHours: [
        {
          day_of_week: 5,
          open_hour: 9,
          open_minutes: 0,
          close_hour: 17,
          close_minutes: 0,
          closed_all_day: false,
          open_all_day: false,
        },
      ],
    };
  });

  afterEach(() => {
    vi.clearAllTimers();
    vi.useRealTimers();
    window.chatwootWebChannel = originalChannel;
  });

  it.each([
    ['16:59', true, false],
    ['08:59', false, true],
  ])('updates a mounted header across %s', async (start, before, after) => {
    vi.setSystemTime(new Date(`2026-09-18T${start}:00Z`));
    const wrapper = shallowMount(ChatHeader, {
      ...mountOptions,
      props: { ...mountOptions.props },
    });
    expect(wrapper.find('.bg-n-teal-10').exists()).toBe(before);

    await vi.advanceTimersByTimeAsync(120000);
    expect(wrapper.find('.bg-n-teal-10').exists()).toBe(after);

    await wrapper.setProps({ availableAgents: [] });
    expect(wrapper.find('.bg-n-teal-10').exists()).toBe(false);
    await wrapper.setProps({ availableAgents: [{ id: 2 }] });
    expect(wrapper.find('.bg-n-teal-10').exists()).toBe(after);

    const fresh = shallowMount(ChatHeader, {
      ...mountOptions,
      props: { ...mountOptions.props },
    });
    expect(fresh.find('.bg-n-teal-10').exists()).toBe(after);
  });

  it.each([
    ['08:59:59.500', false, true],
    ['16:59:59.500', true, false],
  ])('refreshes within one second of %s', async (start, before, after) => {
    vi.setSystemTime(new Date(`2026-09-18T${start}Z`));
    const wrapper = shallowMount(ChatHeader, {
      ...mountOptions,
      props: { ...mountOptions.props },
    });
    expect(wrapper.find('.bg-n-teal-10').exists()).toBe(before);

    await vi.advanceTimersByTimeAsync(1000);
    expect(wrapper.find('.bg-n-teal-10').exists()).toBe(after);
  });

  it('uses agent presence outside hours when working hours are disabled', async () => {
    vi.setSystemTime(new Date('2026-09-18T16:59:00Z'));
    window.chatwootWebChannel.workingHoursEnabled = false;
    const wrapper = shallowMount(ChatHeader, {
      ...mountOptions,
      props: { ...mountOptions.props },
    });
    expect(wrapper.find('.bg-n-teal-10').exists()).toBe(true);

    await vi.advanceTimersByTimeAsync(120000);
    expect(wrapper.find('.bg-n-teal-10').exists()).toBe(true);
    await wrapper.setProps({ availableAgents: [] });
    expect(wrapper.find('.bg-n-teal-10').exists()).toBe(false);
    await wrapper.setProps({ availableAgents: [{ id: 2 }] });
    expect(wrapper.find('.bg-n-teal-10').exists()).toBe(true);
  });

  it('disposes its timer and starts a fresh clock when remounted', async () => {
    vi.setSystemTime(new Date('2026-09-18T16:59:00Z'));
    const timersBeforeMount = vi.getTimerCount();
    const wrapper = shallowMount(ChatHeader, {
      ...mountOptions,
      props: { ...mountOptions.props },
    });
    expect(vi.getTimerCount()).toBe(timersBeforeMount + 1);
    expect(wrapper.find('.bg-n-teal-10').exists()).toBe(true);

    wrapper.unmount();
    expect(vi.getTimerCount()).toBe(timersBeforeMount);
    await vi.advanceTimersByTimeAsync(120000);
    const fresh = shallowMount(ChatHeader, {
      ...mountOptions,
      props: { ...mountOptions.props },
    });
    expect(fresh.find('.bg-n-teal-10').exists()).toBe(false);
    fresh.unmount();
    expect(vi.getTimerCount()).toBe(timersBeforeMount);
  });
});
