import { mount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import ConversationHeatmapContainer from '../heatmaps/ConversationHeatmapContainer.vue';
import reports from 'dashboard/store/modules/reports';

vi.mock('dashboard/helper/AnalyticsHelper', () => ({
  default: { track: vi.fn() },
}));

describe('ConversationHeatmapContainer automatic refresh', () => {
  let wrapper;
  let store;
  let get;
  const series = [{ timestamp: 1789732800, value: 1 }];

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-09-18T12:00:00Z'));
    window.history.replaceState({}, '', '/app/accounts/1/reports/overview');
    get = vi.fn().mockResolvedValue({ data: series });
    vi.stubGlobal('axios', { get });
    store = createStore({
      ...reports,
      state: JSON.parse(JSON.stringify(reports.state)),
      getters: { ...reports.getters, 'inboxes/getInboxes': () => [] },
      actions: { ...reports.actions, 'inboxes/get': vi.fn() },
    });
  });

  afterEach(() => {
    wrapper?.unmount();
    window.history.replaceState({}, '', '/');
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('releases loading after failure and retries at the next interval', async () => {
    let rejectRequest;
    get.mockImplementationOnce(
      () =>
        new Promise((resolve, reject) => {
          rejectRequest = reject;
        })
    );
    wrapper = mount(ConversationHeatmapContainer, {
      global: {
        plugins: [store],
        stubs: { BaseHeatmap: true },
        directives: { 'on-clickaway': () => {} },
      },
    });
    await flushPromises();
    expect(get).toHaveBeenCalledTimes(1);
    expect(
      store.getters.getOverviewUIFlags.isFetchingAccountConversationsHeatmap
    ).toBe(true);

    rejectRequest(new Error('Temporary report failure'));
    await flushPromises();
    const loadingAfterFailure =
      store.getters.getOverviewUIFlags.isFetchingAccountConversationsHeatmap;
    await vi.advanceTimersByTimeAsync(60000);
    await flushPromises();
    expect({
      loadingAfterFailure,
      callsAfterTimer: get.mock.calls.length,
    }).toEqual({
      loadingAfterFailure: false,
      callsAfterTimer: 2,
    });
  });

  it('continues refreshing after a successful initial fetch', async () => {
    wrapper = mount(ConversationHeatmapContainer, {
      global: {
        plugins: [store],
        stubs: { BaseHeatmap: true },
        directives: { 'on-clickaway': () => {} },
      },
    });
    await flushPromises();
    expect(
      store.getters.getOverviewUIFlags.isFetchingAccountConversationsHeatmap
    ).toBe(false);
    await vi.advanceTimersByTimeAsync(60000);
    await flushPromises();
    expect(get).toHaveBeenCalledTimes(2);
    expect(
      store.getters.getOverviewUIFlags.isFetchingAccountConversationsHeatmap
    ).toBe(false);
  });

  it('does not duplicate a pending request', async () => {
    let resolveRequest;
    get.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolveRequest = resolve;
        })
    );
    wrapper = mount(ConversationHeatmapContainer, {
      global: {
        plugins: [store],
        stubs: { BaseHeatmap: true },
        directives: { 'on-clickaway': () => {} },
      },
    });
    await flushPromises();
    await vi.advanceTimersByTimeAsync(60000);
    expect(get).toHaveBeenCalledTimes(1);
    expect(
      store.getters.getOverviewUIFlags.isFetchingAccountConversationsHeatmap
    ).toBe(true);
    resolveRequest({ data: series });
    await flushPromises();
    await vi.advanceTimersByTimeAsync(60000);
    expect(get).toHaveBeenCalledTimes(2);
  });

  it('retains data and resumes after a scheduled refresh fails', async () => {
    get
      .mockResolvedValueOnce({ data: series })
      .mockRejectedValueOnce(new Error('Temporary report failure'));
    wrapper = mount(ConversationHeatmapContainer, {
      global: {
        plugins: [store],
        stubs: { BaseHeatmap: true },
        directives: { 'on-clickaway': () => {} },
      },
    });
    await flushPromises();
    expect(store.getters.getAccountConversationHeatmapData).toEqual(series);
    await vi.advanceTimersByTimeAsync(60000);
    await flushPromises();
    expect(
      store.getters.getOverviewUIFlags.isFetchingAccountConversationsHeatmap
    ).toBe(false);
    expect(store.getters.getAccountConversationHeatmapData).toEqual(series);
    await vi.advanceTimersByTimeAsync(60000);
    await flushPromises();
    expect(get).toHaveBeenCalledTimes(3);
    expect(
      store.getters.getOverviewUIFlags.isFetchingAccountConversationsHeatmap
    ).toBe(false);
  });
});
