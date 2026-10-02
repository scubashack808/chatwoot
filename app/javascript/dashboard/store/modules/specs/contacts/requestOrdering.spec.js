import axios from 'axios';
import Contacts from '../../contacts';
import types from '../../../mutation-types';

vi.mock('axios');
global.axios = axios;
const { actions } = Contacts;

// Exercise all writers against each other: they own the same list and flags.
describe.each(['get', 'search', 'active', 'filter'])('%s ordering', older => {
  it.each(['get', 'search', 'active', 'filter'])(
    'ignores a late response after a newer %s request',
    async newer => {
      const commit = vi.fn();
      let resolveOlder;
      const pending = new Promise(resolve => {
        resolveOlder = resolve;
      });
      axios.get.mockReturnValueOnce(pending);
      axios.post.mockReturnValueOnce(pending);
      const first = actions[older]({ commit }, {});
      const response = {
        data: { payload: [{ id: 2 }], meta: { count: 2, current_page: 1 } },
      };
      axios.get.mockReset().mockResolvedValue(response);
      axios.post.mockReset().mockResolvedValue(response);
      await actions[newer]({ commit }, {});
      expect(commit.mock.calls).toEqual([
        [types.SET_CONTACT_UI_FLAG, { isFetching: true }],
        [types.SET_CONTACT_UI_FLAG, { isFetching: true }],
        [types.CLEAR_CONTACTS],
        [types.SET_CONTACTS, response.data.payload],
        [types.SET_CONTACT_META, response.data.meta],
        [types.SET_CONTACT_UI_FLAG, { isFetching: false }],
      ]);
      commit.mockClear();
      resolveOlder({ data: { payload: [{ id: 1 }], meta: { count: 99 } } });
      await first;
      expect(commit).not.toHaveBeenCalled();
    }
  );

  it('does not clear loading when an obsolete request rejects', async () => {
    const commit = vi.fn();
    let rejectOlder;
    const pending = new Promise((resolve, reject) => {
      rejectOlder = reject;
    });
    axios.get.mockReturnValueOnce(pending);
    axios.post.mockReturnValueOnce(pending);
    const first = actions[older]({ commit }, {});
    let resolveNewer;
    axios.get.mockReset().mockReturnValueOnce(
      new Promise(resolve => {
        resolveNewer = resolve;
      })
    );
    const second = actions.get({ commit });
    commit.mockClear();
    rejectOlder(new Error('obsolete request'));
    await first;
    expect(commit).not.toHaveBeenCalled();
    resolveNewer({ data: { payload: [], meta: {} } });
    await second;
    expect(commit).toHaveBeenLastCalledWith(types.SET_CONTACT_UI_FLAG, {
      isFetching: false,
    });
  });
});

it.each(['success', 'failure'])(
  'keeps read-only filter %s independent of list loading and ordering',
  async outcome => {
    const commit = vi.fn();
    let resolveList;
    axios.get.mockReturnValueOnce(
      new Promise(resolve => {
        resolveList = resolve;
      })
    );
    const list = actions.get({ commit });
    commit.mockClear();
    const payload = [{ id: 3 }];
    if (outcome === 'success') {
      axios.post.mockResolvedValueOnce({ data: { payload } });
    } else {
      axios.post.mockRejectedValueOnce(new Error('lookup failed'));
    }
    expect(await actions.filter({ commit }, { resetState: false })).toEqual(
      outcome === 'success' ? payload : []
    );
    expect(commit).not.toHaveBeenCalled();
    resolveList({ data: { payload: [{ id: 2 }], meta: { count: 1 } } });
    await list;
    expect(commit).toHaveBeenCalledWith(types.SET_CONTACTS, [{ id: 2 }]);
    expect(commit).toHaveBeenLastCalledWith(types.SET_CONTACT_UI_FLAG, {
      isFetching: false,
    });
  }
);
