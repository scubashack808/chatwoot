import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import { createRouter, createMemoryHistory } from 'vue-router';
import { getUnixStartOfDay, getUnixEndOfDay } from 'helpers/DateHelper';
import CsatResponses from '../CsatResponses.vue';
import CsatTable from '../components/CsatTable.vue';
import CsatFilters from '../components/Csat/CsatFilters.vue';
import CsatEmptyState from '../components/CsatEmptyState.vue';
import AddFilterChip from '../components/Filters/v3/AddFilterChip.vue';
import ActiveFilterChip from '../components/Filters/v3/ActiveFilterChip.vue';
import WootDatePicker from 'dashboard/components/ui/DatePicker/DatePicker.vue';
import Pagination from 'dashboard/components/table/Pagination.vue';
import csat from 'dashboard/store/modules/csat';

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));

const responses = Array.from({ length: 26 }, (_, i) => ({
  id: i + 1,
  rating: 5,
  inbox_id: i === 0 ? 4 : 5,
  feedback_message: `Synthetic response ${i + 1}`,
  created_at: Date.parse('2026-09-18T10:00:00Z') / 1000,
  conversation_id: i + 1,
  contact: { id: i + 1, name: `Synthetic contact ${i + 1}` },
  assigned_agent: null,
}));

describe('CsatResponses pagination with filters', () => {
  let wrapper;
  let store;
  let get;

  const listCalls = () =>
    get.mock.calls.filter(([url]) => !url.endsWith('/metrics'));
  const lastListParams = () => listCalls().at(-1)[1].params;
  const recordIds = () => store.state.csat.records.map(row => row.id);
  const clickPage = async label => {
    await wrapper
      .findComponent(Pagination)
      .findAll('button')
      .find(button => button.text() === label)
      .trigger('click');
    await flushPromises();
  };
  const addFilter = async item => {
    wrapper
      .findComponent(CsatFilters)
      .findComponent(AddFilterChip)
      .vm.$emit('addFilter', item);
    await flushPromises();
  };

  beforeEach(async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-09-18T12:00:00Z'));
    window.history.replaceState({}, '', '/app/accounts/1/reports/csat');

    get = vi.fn(async (url, { params }) => {
      const selected = responses.filter(
        row =>
          (!params.inbox_id || row.inbox_id === params.inbox_id) &&
          (!params.rating || row.rating === params.rating)
      );
      if (url.endsWith('/metrics')) {
        return {
          data: {
            total_count: selected.length,
            ratings_count: { 5: selected.length },
            total_sent_messages_count: selected.length,
          },
        };
      }
      return { data: selected.slice((params.page - 1) * 25, params.page * 25) };
    });
    vi.stubGlobal('axios', { get });

    store = createStore({
      modules: {
        csat: { ...csat, state: JSON.parse(JSON.stringify(csat.state)) },
      },
      getters: {
        getCurrentAccountId: () => 1,
        'accounts/isFeatureEnabledonAccount': () => () => true,
        'accounts/getAccount': () => () => ({ id: 1 }),
        'globalConfig/isOnChatwootCloud': () => false,
        'globalConfig/isMetaInboxCreationDisabled': () => false,
        'globalConfig/isMetaMessageSendingDisabled': () => false,
        'agents/getAgents': () => [{ id: 7, name: 'Agent' }],
        'teams/getTeams': () => [{ id: 2, name: 'Team' }],
        'inboxes/getInboxes': () => [
          { id: 4, name: 'One response inbox' },
          { id: 5, name: 'Other inbox' },
        ],
      },
      actions: { 'agents/get': () => {} },
    });

    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        {
          path: '/app/accounts/:accountId/reports/csat',
          component: { template: '<div />' },
        },
      ],
    });
    await router.push('/app/accounts/1/reports/csat');
    await router.isReady();

    wrapper = mount(CsatResponses, {
      global: {
        plugins: [router, store],
        stubs: {
          ReportHeader: true,
          CsatMetrics: true,
          WootDatePicker: true,
          ActiveFilterChip: true,
          AddFilterChip: true,
          CsatContactCell: true,
          CsatExpandedRow: true,
          UserAvatarWithName: true,
          ShowMore: true,
        },
      },
    });
    await flushPromises();
    expect(recordIds()).toHaveLength(25);
  });

  afterEach(() => {
    wrapper?.unmount();
    window.history.replaceState({}, '', '/');
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it('requests the first page when filters narrow results from page two', async () => {
    await clickPage('2');
    expect(lastListParams().page).toBe(2);
    expect(recordIds()).toEqual([26]);

    await addFilter({ type: 'inboxes', id: 4, name: 'One response inbox' });

    const narrowed = {
      page: lastListParams().page,
      count: store.state.csat.metrics.totalResponseCount,
      records: recordIds(),
      empty: wrapper.findComponent(CsatEmptyState).exists(),
      controlledPageIndex: wrapper.findComponent(CsatTable).props('pageIndex'),
    };

    await clickPage('1');
    expect(recordIds()).toEqual([1]);

    expect(narrowed).toEqual({
      page: 1,
      count: 1,
      records: [1],
      empty: false,
      controlledPageIndex: 0,
    });
  });

  it('shows the single match when narrowing from page one', async () => {
    await addFilter({ type: 'inboxes', id: 4, name: 'One response inbox' });

    expect(lastListParams().page).toBe(1);
    expect(store.state.csat.metrics.totalResponseCount).toBe(1);
    expect(recordIds()).toEqual([1]);
    expect(wrapper.findComponent(CsatEmptyState).exists()).toBe(false);
  });

  it('keeps ordinary page navigation for wide results', async () => {
    await clickPage('2');
    expect(lastListParams().page).toBe(2);
    expect(recordIds()).toEqual([26]);
    expect(wrapper.findComponent(CsatTable).props('pageIndex')).toBe(1);

    await clickPage('1');
    expect(lastListParams().page).toBe(1);
    expect(recordIds()).toEqual(responses.slice(0, 25).map(row => row.id));
    expect(wrapper.findComponent(CsatTable).props('pageIndex')).toBe(0);
  });

  describe('every filter change from page two requests page one', () => {
    it.each([
      [{ type: 'agents', id: 7 }, { user_ids: [7] }],
      [{ type: 'inboxes', id: 5 }, { inbox_id: 5 }],
      [{ type: 'teams', id: 2 }, { team_id: 2 }],
      [{ type: 'ratings', id: 5 }, { rating: 5 }],
    ])('adding %o', async (item, expectedParams) => {
      await clickPage('2');

      await addFilter(item);

      expect(lastListParams()).toMatchObject({ page: 1, ...expectedParams });
      expect(wrapper.findComponent(CsatTable).props('pageIndex')).toBe(0);
    });

    it('changing the date range', async () => {
      await clickPage('2');
      const start = new Date('2026-09-01T00:00:00Z');
      const end = new Date('2026-09-18T00:00:00Z');

      wrapper
        .findComponent(WootDatePicker)
        .vm.$emit('dateRangeChanged', [start, end, 'custom']);
      await flushPromises();

      expect(lastListParams()).toMatchObject({
        page: 1,
        since: getUnixStartOfDay(start),
        until: getUnixEndOfDay(end),
      });
      expect(wrapper.findComponent(CsatTable).props('pageIndex')).toBe(0);
    });

    it('removing a filter', async () => {
      await addFilter({ type: 'ratings', id: 5 });
      await clickPage('2');
      expect(lastListParams()).toMatchObject({ page: 2, rating: 5 });

      wrapper
        .findComponent(CsatFilters)
        .findComponent(ActiveFilterChip)
        .vm.$emit('removeFilter', 'ratings');
      await flushPromises();

      expect(lastListParams()).toMatchObject({ page: 1, rating: undefined });
      expect(wrapper.findComponent(CsatTable).props('pageIndex')).toBe(0);
      expect(recordIds()).toHaveLength(25);
    });
  });
});
