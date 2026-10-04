import { mount, flushPromises } from '@vue/test-utils';
import { createRouter, createMemoryHistory } from 'vue-router';
import { createStore } from 'vuex';
import SLAReports from '../SLAReports.vue';
import DatePicker from 'dashboard/components/ui/DatePicker/DatePicker.vue';
import slaReports from 'dashboard/store/modules/SLAReports';

const savedRange = {
  from: String(Date.parse('2026-08-03T00:00:00Z') / 1000),
  to: String(Date.parse('2026-08-09T23:59:59Z') / 1000),
  range: 'custom',
};

describe('SLAReports saved date initialization', () => {
  let wrapper;
  let get;

  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-09-18T12:00:00Z'));
    window.history.replaceState({}, '', '/app/accounts/1/reports/sla');
    get = vi.fn(async url => {
      if (url.endsWith('/metrics')) {
        return {
          data: {
            total_applied_slas: 1,
            number_of_sla_misses: 0,
            hit_rate: '100%',
          },
        };
      }
      return { data: { payload: [], meta: { count: 0, current_page: 1 } } };
    });
    vi.stubGlobal('axios', { get });
  });

  afterEach(() => {
    wrapper?.unmount();
    window.history.replaceState({}, '', '/');
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it.each([
    {
      name: 'saved dates without entity filters',
      query: savedRange,
      start: '2026-08-03T00:00:00.000Z',
      end: '2026-08-09T23:59:59.000Z',
      range: 'custom',
    },
    {
      name: 'saved dates with an inbox filter',
      query: { ...savedRange, inbox_id: '4' },
      start: '2026-08-03T00:00:00.000Z',
      end: '2026-08-09T23:59:59.000Z',
      range: 'custom',
    },
    {
      name: 'the default last-seven-day range without query parameters',
      query: {},
      start: '2026-09-12T00:00:00.000Z',
      end: '2026-09-18T23:59:59.000Z',
      range: 'last7days',
    },
  ])(
    'requests the displayed range for $name',
    async ({ query, start, end, range }) => {
      const router = createRouter({
        history: createMemoryHistory(),
        routes: [
          {
            path: '/app/accounts/:accountId/reports/sla',
            component: { template: '<div />' },
          },
        ],
      });
      await router.push({ path: '/app/accounts/1/reports/sla', query });
      await router.isReady();
      const store = createStore({
        modules: {
          slaReports: {
            ...slaReports,
            state: JSON.parse(JSON.stringify(slaReports.state)),
          },
        },
        getters: {
          getCurrentAccountId: () => 1,
          'agents/getAgents': () => [],
          'inboxes/getInboxes': () => [{ id: 4, name: 'Synthetic inbox' }],
          'teams/getTeams': () => [],
          'labels/getLabels': () => [],
          'sla/getSLA': () => [],
        },
        actions: {
          'agents/get': vi.fn(),
          'inboxes/get': vi.fn(),
          'teams/get': vi.fn(),
          'labels/get': vi.fn(),
          'sla/get': vi.fn(),
        },
      });
      wrapper = mount(SLAReports, {
        global: {
          plugins: [router, store],
          directives: { 'on-clickaway': {} },
          stubs: {
            ReportHeader: true,
            SLAMetrics: true,
            SLATable: true,
            ActiveFilterChip: true,
            AddFilterChip: true,
            CalendarDateInput: true,
            CalendarDateRange: true,
            CalendarYear: true,
            CalendarMonth: true,
            CalendarWeek: true,
            CalendarFooter: true,
          },
        },
      });
      await flushPromises();

      const picker = wrapper.findComponent(DatePicker);
      expect(
        picker.props('dateRange').map(date => date.toISOString().slice(0, 10))
      ).toEqual([start.slice(0, 10), end.slice(0, 10)]);
      expect(picker.props('rangeType')).toBe(range);
      const since = Date.parse(start) / 1000;
      const until = Date.parse(end) / 1000;
      expect(router.currentRoute.value.query).toEqual({
        from: String(since),
        to: String(until),
        range,
        ...(query.inbox_id ? { inbox_id: query.inbox_id } : {}),
      });
      expect(new Set(get.mock.calls.map(([url]) => url))).toEqual(
        new Set([
          '/api/v1/accounts/1/applied_slas',
          '/api/v1/accounts/1/applied_slas/metrics',
        ])
      );
      get.mock.calls.forEach(([, { params }]) => {
        expect(params).toMatchObject({ since, until });
        if (query.inbox_id) {
          expect(params.inbox_id).toBe(Number(query.inbox_id));
        } else {
          expect(params.inbox_id).toBeFalsy();
        }
      });
    }
  );
});
