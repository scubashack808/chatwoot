import { createStore } from 'vuex';
import NotificationsAPI from '../../../../api/notifications';
import notifications from '../../notifications';
import { getters } from '../../notifications/getters';

vi.mock('../../../../api/notifications', () => ({
  default: { get: vi.fn() },
}));

describe.each(['getFilteredNotifications', 'getFilteredNotificationsV4'])(
  '#%s activity ordering',
  getterName => {
    let store;
    let rows;

    beforeEach(() => {
      store = createStore({
        modules: {
          notifications: {
            ...notifications,
            state: structuredClone(notifications.state),
          },
        },
      });
      rows = [
        {
          id: 1,
          primary_actor_id: 11,
          created_at: 100,
          last_activity_at: 100,
          read_at: null,
          snoozed_until: null,
        },
        {
          id: 2,
          primary_actor_id: 22,
          created_at: 200,
          last_activity_at: 200,
          read_at: null,
          snoozed_until: null,
        },
      ];
      NotificationsAPI.get.mockResolvedValue({
        data: {
          data: {
            payload: rows,
            meta: { count: 2, unread_count: 2, current_page: 1 },
          },
        },
      });
    });

    it.each([
      ['desc', [2, 1]],
      ['asc', [1, 2]],
    ])('keeps ordinary ordering for %s', async (sortOrder, expectedIds) => {
      await store.dispatch('notifications/index', { sortOrder });
      expect(
        store.getters[`notifications/${getterName}`]({ sortOrder }).map(
          notification => notification.id
        )
      ).toEqual(expectedIds);
    });

    it('keeps one notification per actor after refetching', async () => {
      await store.dispatch('notifications/index');
      rows[0] = { ...rows[0], id: 3, created_at: 300, last_activity_at: 300 };
      await store.dispatch('notifications/index');

      expect(store.state.notifications.records[1]).toBeUndefined();
      expect(
        store.getters[`notifications/${getterName}`]({ sortOrder: 'desc' }).map(
          notification => notification.id
        )
      ).toEqual([3, 2]);
    });

    it.each([
      ['desc', [1, 2]],
      ['asc', [2, 1]],
    ])(
      'keeps fetched activity ordering for %s',
      async (sortOrder, expectedIds) => {
        rows[0].last_activity_at = 300;
        if (sortOrder === 'asc') rows.reverse();
        await store.dispatch('notifications/index', { sortOrder });

        const result = store.getters[`notifications/${getterName}`]({
          sortOrder,
        });
        expect(result.map(notification => notification.id)).toEqual(
          expectedIds
        );
        if (getterName === 'getFilteredNotificationsV4') {
          expect(
            result.find(notification => notification.id === 1)
          ).toMatchObject({
            primaryActorId: 11,
            createdAt: 100,
            lastActivityAt: 300,
            snoozedUntil: null,
          });
        }
      }
    );

    it.each([
      ['desc', [2, 1], [1, 2]],
      ['asc', [1, 2], [2, 1]],
    ])(
      'repositions a realtime reopened reminder for %s',
      async (sortOrder, initialIds, expectedIds) => {
        rows[0].snoozed_until = 250;
        rows[0].read_at = 90;
        await store.dispatch('notifications/index', { sortOrder });
        expect(
          store.getters[`notifications/${getterName}`]({ sortOrder }).map(
            notification => notification.id
          )
        ).toEqual(initialIds);

        await store.dispatch('notifications/updateNotification', {
          notification: {
            ...rows[0],
            last_activity_at: 300,
            snoozed_until: null,
            read_at: null,
          },
          unread_count: 2,
          count: 2,
        });
        expect(store.state.notifications.records[1]).toMatchObject({
          created_at: 100,
          last_activity_at: 300,
          snoozed_until: null,
          read_at: null,
        });
        expect(
          store.getters[`notifications/${getterName}`]({ sortOrder }).map(
            notification => notification.id
          )
        ).toEqual(expectedIds);
      }
    );
  }
);

describe('#getters', () => {
  it('getFilteredNotifications', () => {
    const state = {
      records: {
        1: {
          id: 1,
          created_at: 300,
          last_activity_at: 300,
          read_at: '2024-02-07T11:42:39.988Z',
          snoozed_until: null,
        },
        2: {
          id: 2,
          created_at: 200,
          last_activity_at: 200,
          read_at: null,
          snoozed_until: null,
        },
        3: {
          id: 3,
          created_at: 100,
          last_activity_at: 100,
          read_at: '2024-02-07T11:42:39.988Z',
          snoozed_until: '2024-02-07T11:42:39.988Z',
        },
      },
    };
    const filters = {
      type: 'read',
      status: 'snoozed',
      sortOrder: 'desc',
    };
    expect(getters.getFilteredNotifications(state)(filters)).toEqual([
      state.records[1],
      state.records[2],
      state.records[3],
    ]);
  });

  it('getNotificationById', () => {
    const state = {
      records: {
        1: { id: 1 },
      },
    };
    expect(getters.getNotificationById(state)(1)).toEqual({ id: 1 });
    expect(getters.getNotificationById(state)(2)).toEqual({});
  });

  it('getUIFlags', () => {
    const state = {
      uiFlags: {
        isFetching: true,
      },
    };
    expect(getters.getUIFlags(state)).toEqual({
      isFetching: true,
    });
  });

  it('getNotification', () => {
    const state = {
      records: {
        1: { id: 1 },
      },
    };
    expect(getters.getNotification(state)(1)).toEqual({ id: 1 });
    expect(getters.getNotification(state)(2)).toEqual({});
  });

  it('getMeta', () => {
    const state = {
      meta: { unreadCount: 1 },
    };
    expect(getters.getMeta(state)).toEqual({ unreadCount: 1 });
  });

  it('getNotificationFilters', () => {
    const state = {
      notificationFilters: {
        page: 1,
        status: 'unread',
        type: 'all',
        sortOrder: 'desc',
      },
    };
    expect(getters.getNotificationFilters(state)).toEqual(
      state.notificationFilters
    );
  });

  describe('getHasUnreadNotifications', () => {
    it('should return true when there are unread notifications', () => {
      const state = {
        meta: { unreadCount: 5 },
      };
      expect(getters.getHasUnreadNotifications(state)).toBe(true);
    });

    it('should return false when there are no unread notifications', () => {
      const state = {
        meta: { unreadCount: 0 },
      };
      expect(getters.getHasUnreadNotifications(state)).toBe(false);
    });

    it('should return false when meta is empty', () => {
      const state = {
        meta: {},
      };
      expect(getters.getHasUnreadNotifications(state)).toBe(false);
    });
  });
});
