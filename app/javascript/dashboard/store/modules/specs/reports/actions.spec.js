import axios from 'axios';
import { createStore } from 'vuex';
import reports, { actions } from '../../reports';
import * as types from '../../../mutation-types';
import { STATUS } from '../../../constants';
import * as DownloadHelper from 'dashboard/helper/downloadHelper';
import { flushPromises } from '@vue/test-utils';

global.open = vi.fn();
global.axios = axios;
global.URL.createObjectURL = vi.fn();

vi.mock('axios');
vi.spyOn(DownloadHelper, 'downloadCsvFile');

describe('#actions', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('report series through the store', () => {
    let store;
    const from = 1785888000;
    const to = 1788911999;
    const weekly = [
      { value: 1, timestamp: 1785628800 },
      { value: 1, timestamp: 1786233600 },
      { value: 0, timestamp: 1786838400 },
      { value: 0, timestamp: 1787443200 },
      { value: 0, timestamp: 1788048000 },
      { value: 0, timestamp: 1788652800 },
    ];

    beforeEach(() => {
      store = createStore({
        ...reports,
        state: JSON.parse(JSON.stringify(reports.state)),
      });
    });

    it('retains the first partial week containing in-range conversations', async () => {
      axios.get.mockResolvedValue({ data: weekly });
      store.dispatch('fetchAccountReport', {
        metric: 'conversations_count',
        type: 'account',
        from,
        to,
        groupBy: 'week',
        businessHours: false,
      });
      expect(
        store.getters.getAccountReports.isFetching.conversations_count
      ).toBe(true);
      await flushPromises();

      const report = store.getters.getAccountReports;
      expect(
        report.data.conversations_count.reduce((sum, row) => sum + row.value, 0)
      ).toBe(2);
      expect(report.data.conversations_count).toEqual(weekly);
      expect(report.data.conversations_count[0].timestamp).toBe(1785628800);
      expect(report.isFetching.conversations_count).toBe(false);
      expect(axios.get).toHaveBeenCalledWith(expect.any(String), {
        params: expect.objectContaining({
          since: from,
          until: to,
          group_by: 'week',
        }),
      });
    });

    it.each([
      [
        'day',
        from,
        [
          { value: 1, timestamp: from },
          { value: 1, timestamp: 1786320000 },
        ],
      ],
      ['week', 1785628800, weekly],
      ['week', from, []],
      ['month', from, [{ value: 12, count: 2, timestamp: 1785542400 }]],
      ['year', from, [{ value: 12, count: 2, timestamp: 1767225600 }]],
    ])(
      'preserves %s response fields and buckets',
      async (groupBy, start, data) => {
        axios.get.mockResolvedValue({ data });
        store.dispatch('fetchAccountReport', {
          metric: 'avg_first_response_time',
          from: start,
          to,
          groupBy,
        });
        await flushPromises();
        expect(
          store.getters.getAccountReports.data.avg_first_response_time
        ).toEqual(data);
        expect(
          store.getters.getAccountReports.isFetching.avg_first_response_time
        ).toBe(false);
      }
    );

    it.each([
      [
        'fetchAccountConversationHeatmap',
        'getAccountConversationHeatmapData',
        'isFetchingAccountConversationsHeatmap',
      ],
      [
        'fetchAccountResolutionHeatmap',
        'getAccountResolutionHeatmapData',
        'isFetchingAccountResolutionsHeatmap',
      ],
    ])('keeps hourly clamping for %s', async (action, getter, loadingFlag) => {
      const data = [from - 1, from, to - 1, to].map(timestamp => ({
        timestamp,
        value: 1,
      }));
      axios.get.mockResolvedValue({ data });
      store.dispatch(action, { metric: 'conversations_count', from, to });
      expect(store.getters.getOverviewUIFlags[loadingFlag]).toBe(true);
      await flushPromises();
      expect(store.getters[getter]).toEqual(data.slice(1, 3));
      expect(store.getters.getOverviewUIFlags[loadingFlag]).toBe(false);
    });
  });

  describe('#fetchAccountSummary', () => {
    it('sends correct actions if API is success', async () => {
      const commit = vi.fn();
      const reportObj = {
        from: 1630504922510,
        to: 1630504922510,
        type: 'account',
        id: 1,
        groupBy: 'day',
        businessHours: true,
      };
      const summaryData = {
        conversations_count: 10,
        incoming_messages_count: 20,
        outgoing_messages_count: 15,
        avg_first_response_time: 30,
        avg_resolution_time: 60,
        resolutions_count: 5,
        bot_resolutions_count: 2,
        bot_handoffs_count: 1,
        reply_time: 25,
      };
      axios.get.mockResolvedValue({ data: summaryData });

      actions.fetchAccountSummary({ commit }, reportObj);
      await flushPromises();

      expect(commit.mock.calls).toEqual([
        [types.default.SET_ACCOUNT_SUMMARY_STATUS, STATUS.FETCHING],
        [types.default.SET_ACCOUNT_SUMMARY, summaryData],
        [types.default.SET_ACCOUNT_SUMMARY_STATUS, STATUS.FINISHED],
      ]);
    });

    it('sends correct actions if API fails', async () => {
      const commit = vi.fn();
      const reportObj = {
        from: 1630504922510,
        to: 1630504922510,
      };
      axios.get.mockRejectedValue(new Error('API Error'));

      actions.fetchAccountSummary({ commit }, reportObj);
      await flushPromises();

      expect(commit.mock.calls).toEqual([
        [types.default.SET_ACCOUNT_SUMMARY_STATUS, STATUS.FETCHING],
        [types.default.SET_ACCOUNT_SUMMARY_STATUS, STATUS.FAILED],
      ]);
    });
  });

  describe('#fetchBotSummary', () => {
    it('sends correct actions if API is success', async () => {
      const commit = vi.fn();
      const reportObj = {
        from: 1630504922510,
        to: 1630504922510,
        groupBy: 'day',
        businessHours: true,
      };
      const summaryData = {
        bot_resolutions_count: 10,
        bot_handoffs_count: 5,
        previous: {
          bot_resolutions_count: 8,
          bot_handoffs_count: 4,
        },
      };
      axios.get.mockResolvedValue({ data: summaryData });

      actions.fetchBotSummary({ commit }, reportObj);
      await flushPromises();

      expect(commit.mock.calls).toEqual([
        [types.default.SET_BOT_SUMMARY_STATUS, STATUS.FETCHING],
        [types.default.SET_BOT_SUMMARY, summaryData],
        [types.default.SET_BOT_SUMMARY_STATUS, STATUS.FINISHED],
      ]);
    });

    it('sends correct actions if API fails', async () => {
      const commit = vi.fn();
      const reportObj = {
        from: 1630504922510,
        to: 1630504922510,
      };
      const error = new Error('API error');
      axios.get.mockRejectedValueOnce(error);

      actions.fetchBotSummary({ commit }, reportObj);
      await flushPromises();

      expect(commit.mock.calls).toEqual([
        [types.default.SET_BOT_SUMMARY_STATUS, STATUS.FETCHING],
        [types.default.SET_BOT_SUMMARY_STATUS, STATUS.FAILED],
      ]);
    });
  });

  describe('#downloadAgentReports', () => {
    it('open CSV download prompt if API is success', async () => {
      const data = `Agent name,Conversations count,Avg first response time (Minutes),Avg resolution time (Minutes)
      Pranav,36,114,28411`;
      axios.get.mockResolvedValue({ data });

      const param = {
        from: 1630504922510,
        to: 1630504922510,
        fileName: 'agent-report-01-09-2021.csv',
      };
      actions.downloadAgentReports(1, param);
      await flushPromises();

      expect(DownloadHelper.downloadCsvFile).toBeCalledWith(
        param.fileName,
        data
      );
    });
  });

  describe('#downloadLabelReports', () => {
    it('open CSV download prompt if API is success', async () => {
      const data = `Label Title,Conversations count,Avg first response time (Minutes),Avg resolution time (Minutes)
      website,0,0,0`;
      axios.get.mockResolvedValue({ data });
      const param = {
        from: 1632335400,
        to: 1632853800,
        type: 'label',
        fileName: 'label-report-01-09-2021.csv',
      };
      actions.downloadLabelReports(1, param);
      await flushPromises();

      expect(DownloadHelper.downloadCsvFile).toBeCalledWith(
        param.fileName,
        data
      );
    });
  });

  describe('#downloadInboxReports', () => {
    it('open CSV download prompt if API is success', async () => {
      const data = `Inbox name,Conversations count,Avg first response time (Minutes),Avg resolution time (Minutes)
      Fayaz,2,127,0
      EMa,0,0,0
      Twillio WA,0,0,0`;
      axios.get.mockResolvedValue({ data });
      const param = {
        from: 1631039400,
        to: 1635013800,
        fileName: 'inbox-report-24-10-2021.csv',
      };
      actions.downloadInboxReports(1, param);
      await flushPromises();

      expect(DownloadHelper.downloadCsvFile).toBeCalledWith(
        param.fileName,
        data
      );
    });
  });

  describe('#downloadTeamReports', () => {
    it('open CSV download prompt if API is success', async () => {
      const data = `Team name,Conversations count,Avg first response time (Minutes),Avg resolution time (Minutes)
      sales team,0,0,0
      Reporting period 2021-09-23 to 2021-09-29`;
      axios.get.mockResolvedValue({ data });
      const param = {
        from: 1631039400,
        to: 1635013800,
        fileName: 'inbox-report-24-10-2021.csv',
      };
      actions.downloadInboxReports(1, param);
      await flushPromises();

      expect(DownloadHelper.downloadCsvFile).toBeCalledWith(
        param.fileName,
        data
      );
    });
  });

  describe('#downloadConversationsSummaryReports', () => {
    it('open CSV download prompt if API is success', async () => {
      const data = `Conversations,Messages received,Messages sent,Avg first response time,Avg resolution time,Resolution count,Avg customer waiting time
      217,323,623,23 hours 22 minutes,179 days 18 hours,30,48 days 4 hours`;
      axios.get.mockResolvedValue({ data });
      const param = {
        from: 1631039400,
        to: 1635013800,
        fileName: 'conversations-summary-report-24-10-2021.csv',
      };
      actions.downloadConversationsSummaryReports(1, param);
      await flushPromises();

      expect(DownloadHelper.downloadCsvFile).toBeCalledWith(
        param.fileName,
        data
      );
    });
  });
});
