import { createStore } from 'vuex';
import NotificationsAPI from 'dashboard/api/notifications';
import notifications from '../../notifications';

vi.mock('dashboard/api/notifications');

describe('notification deletion reconciliation', () => {
  let store;
  let resolveDelete;

  beforeEach(async () => {
    store = createStore({
      modules: {
        notifications: {
          ...notifications,
          state: JSON.parse(JSON.stringify(notifications.state)),
        },
      },
    });
    NotificationsAPI.get.mockResolvedValue({
      data: {
        data: {
          payload: [
            { id: 1, primary_actor_id: 1, read_at: null },
            { id: 2, primary_actor_id: 2, read_at: null },
          ],
          meta: { count: 2, unread_count: 2, current_page: 1 },
        },
      },
    });
    await store.dispatch('notifications/index');
    NotificationsAPI.delete.mockImplementation(
      () =>
        new Promise(resolve => {
          resolveDelete = resolve;
        })
    );
  });

  it.each([null, 123])(
    'reconciles HTTP-only deletion with read_at %s',
    async readAt => {
      store.state.notifications.records[1].read_at = readAt;
      store.state.notifications.meta.unreadCount = readAt ? 1 : 2;
      const pending = store.dispatch('notifications/delete', {
        notification: store.state.notifications.records[1],
      });
      expect(store.state.notifications.uiFlags.isDeleting).toBe(true);
      expect(Object.keys(store.state.notifications.records)).toEqual([
        '1',
        '2',
      ]);
      resolveDelete({});
      await pending;

      expect(NotificationsAPI.delete).toHaveBeenCalledWith(1);
      expect(Object.keys(store.state.notifications.records)).toEqual(['2']);
      expect(store.getters['notifications/getMeta']).toMatchObject({
        count: 1,
        unreadCount: 1,
      });
      expect(store.getters['notifications/getHasUnreadNotifications']).toBe(
        true
      );
      expect(store.state.notifications.uiFlags.isDeleting).toBe(false);
    }
  );

  it.each(['before', 'after'])(
    'preserves realtime counts when the event arrives %s HTTP',
    async order => {
      const pending = store.dispatch('notifications/delete', {
        notification: store.state.notifications.records[1],
      });
      if (order === 'after') {
        resolveDelete({});
        await pending;
      }
      await store.dispatch('notifications/deleteNotification', {
        notification: { id: 1 },
        count: 1,
        unread_count: 1,
      });
      if (order === 'before') {
        resolveDelete({});
        await pending;
      }

      expect(Object.keys(store.state.notifications.records)).toEqual(['2']);
      expect(store.getters['notifications/getMeta']).toMatchObject({
        count: 1,
        unreadCount: 1,
      });
      expect(store.getters['notifications/getHasUnreadNotifications']).toBe(
        true
      );
      expect(store.state.notifications.uiFlags.isDeleting).toBe(false);
    }
  );

  it('preserves records and counts on rejection and accepts a later event', async () => {
    NotificationsAPI.delete.mockRejectedValue(new Error('Deletion failed'));
    await store.dispatch('notifications/delete', {
      notification: store.state.notifications.records[1],
    });
    expect(Object.keys(store.state.notifications.records)).toEqual(['1', '2']);
    expect(store.getters['notifications/getMeta']).toMatchObject({
      count: 2,
      unreadCount: 2,
    });
    expect(store.getters['notifications/getHasUnreadNotifications']).toBe(true);
    expect(store.state.notifications.uiFlags.isDeleting).toBe(false);

    await store.dispatch('notifications/deleteNotification', {
      notification: { id: 1 },
      count: 1,
      unread_count: 1,
    });
    expect(Object.keys(store.state.notifications.records)).toEqual(['2']);
    expect(store.getters['notifications/getMeta']).toMatchObject({
      count: 1,
      unreadCount: 1,
    });
  });

  it('uses current metadata and read state rather than the request snapshot', async () => {
    const pending = store.dispatch('notifications/delete', {
      notification: { ...store.state.notifications.records[1] },
    });
    await store.dispatch('notifications/updateNotification', {
      notification: { id: 1, read_at: 123 },
      count: 2,
      unread_count: 1,
    });
    await store.dispatch('notifications/addNotification', {
      notification: { id: 3, primary_actor_id: 3, read_at: null },
      count: 3,
      unread_count: 2,
    });
    resolveDelete({});
    await pending;

    expect(Object.keys(store.state.notifications.records)).toEqual(['2', '3']);
    expect(store.getters['notifications/getMeta']).toMatchObject({
      count: 2,
      unreadCount: 2,
    });
    expect(store.getters['notifications/getHasUnreadNotifications']).toBe(true);
  });

  it('hides the indicator when the last unread notification is deleted', async () => {
    store.state.notifications.records[2].read_at = 123;
    store.state.notifications.meta.unreadCount = 1;
    const pending = store.dispatch('notifications/delete', {
      notification: store.state.notifications.records[1],
    });
    resolveDelete({});
    await pending;

    expect(store.getters['notifications/getMeta']).toMatchObject({
      count: 1,
      unreadCount: 0,
    });
    expect(store.getters['notifications/getHasUnreadNotifications']).toBe(
      false
    );
  });
});
