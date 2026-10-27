import { sortComparator } from '../../notifications/helpers';

const notifications = [
  {
    id: 1,
    read_at: '2024-02-07T11:42:39.988Z',
    snoozed_until: null,
    created_at: 1707328400,
    last_activity_at: 1707328400,
  },
  {
    id: 2,
    read_at: null,
    snoozed_until: null,
    created_at: 1707233688,
    last_activity_at: 1707233688,
  },
  {
    id: 3,
    read_at: '2024-01-07T11:42:39.988Z',
    snoozed_until: null,
    created_at: 1707233672,
    last_activity_at: 1707233672,
  },
  {
    id: 4,
    read_at: null,
    snoozed_until: '2024-02-08T03:30:00.000Z',
    created_at: 1707233667,
    last_activity_at: 1707233667,
  },
  {
    id: 5,
    read_at: '2024-02-07T10:42:39.988Z',
    snoozed_until: '2024-02-08T03:30:00.000Z',
    created_at: 1707233662,
    last_activity_at: 1707233662,
  },
  {
    id: 6,
    read_at: null,
    snoozed_until: '2024-02-08T03:30:00.000Z',
    created_at: 1707233561,
    last_activity_at: 1707233561,
  },
];

describe('#sortComparator', () => {
  it.each([
    ['newest', [1, 2, 3, 4, 5, 6]],
    ['oldest', [6, 5, 4, 3, 2, 1]],
  ])('sorts ordinary notifications by %s', (sortOrder, expectedIds) => {
    const sortedNotifications = [...notifications].sort((a, b) =>
      sortComparator(a, b, sortOrder)
    );
    expect(sortedNotifications.map(notification => notification.id)).toEqual(
      expectedIds
    );
  });

  it.each([
    ['newest', [1, 2]],
    ['oldest', [2, 1]],
  ])(
    'sorts returned reminders by activity for %s',
    (sortOrder, expectedIds) => {
      const returnedNotifications = [
        { id: 1, created_at: 100, last_activity_at: 300 },
        { id: 2, created_at: 200, last_activity_at: 200 },
      ];
      const sortedNotifications = returnedNotifications.sort((a, b) =>
        sortComparator(a, b, sortOrder)
      );
      expect(sortedNotifications.map(notification => notification.id)).toEqual(
        expectedIds
      );
    }
  );

  it.each(['newest', 'oldest'])(
    'compares equal activity as equal for %s',
    sortOrder => {
      expect(
        sortComparator(
          { created_at: 100, last_activity_at: 300 },
          { created_at: 200, last_activity_at: 300 },
          sortOrder
        )
      ).toBe(0);
    }
  );

  it('preserves order for an unsupported sort option', () => {
    expect(sortComparator(notifications[0], notifications[1], 'invalid')).toBe(
      0
    );
  });
});
