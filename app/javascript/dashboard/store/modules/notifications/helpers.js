const INBOX_SORT_OPTIONS = {
  newest: 'desc',
  oldest: 'asc',
};

const sortConfig = {
  newest: (a, b) => b.last_activity_at - a.last_activity_at,
  oldest: (a, b) => a.last_activity_at - b.last_activity_at,
};

export const sortComparator = (a, b, sortOrder) => {
  const sortDirection = INBOX_SORT_OPTIONS[sortOrder];
  if (sortOrder === 'newest' || sortOrder === 'oldest') {
    return sortConfig[sortOrder](a, b, sortDirection);
  }
  return 0;
};
