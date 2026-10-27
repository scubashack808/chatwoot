import { mount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import ConversationHeatmapContainer from '../heatmaps/ConversationHeatmapContainer.vue';
import reports from 'dashboard/store/modules/reports';

vi.mock('dashboard/helper/AnalyticsHelper', () => ({
  default: { track: vi.fn() },
}));

describe('Conversation heatmap exclusive date range', () => {
  let wrapper;

  afterEach(() => {
    wrapper?.unmount();
    window.history.replaceState({}, '', '/');
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('requests through next midnight while displaying only seven days', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-09-18T23:59:59Z'));
    window.history.replaceState({}, '', '/app/accounts/1/reports/overview');
    const get = vi.fn().mockResolvedValue({
      data: [
        { timestamp: 1789167600, value: 1 },
        { timestamp: 1789772400, value: 2 },
        { timestamp: 1789776000, value: 1 },
      ],
    });
    vi.stubGlobal('axios', { get });
    const store = createStore({
      ...reports,
      state: JSON.parse(JSON.stringify(reports.state)),
      getters: { ...reports.getters, 'inboxes/getInboxes': () => [] },
      actions: { ...reports.actions, 'inboxes/get': vi.fn() },
    });
    wrapper = mount(ConversationHeatmapContainer, {
      global: {
        plugins: [store],
        stubs: { BaseHeatmap: true },
        directives: { 'on-clickaway': () => {} },
      },
    });
    await flushPromises();
    expect(get).toHaveBeenCalledWith(expect.any(String), {
      params: expect.objectContaining({
        since: 1789171200,
        until: 1789776000,
        group_by: 'hour',
      }),
    });
    expect(
      wrapper.findComponent({ name: 'BaseHeatmap' }).props('numberOfRows')
    ).toBe(7);
    expect(store.getters.getAccountConversationHeatmapData).toEqual([
      { timestamp: 1789772400, value: 2 },
    ]);
  });
});
