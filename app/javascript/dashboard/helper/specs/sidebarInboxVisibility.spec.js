import { filterSidebarInboxes } from '../sidebarInboxVisibility';

const inboxes = [
  { id: 1, name: 'Ethan' },
  { id: 2, name: 'Info - EH' },
  { id: 4, name: 'Admin EH' },
  { id: 9, name: 'RingCentral SMS' },
  { id: 10, name: 'Scuba Shack' },
];

describe('#filterSidebarInboxes', () => {
  it('keeps every authorized inbox when visibility is not configured', () => {
    expect(filterSidebarInboxes(inboxes, {}, 1)).toEqual(inboxes);
  });

  it('keeps every authorized inbox when only another account is configured', () => {
    const uiSettings = {
      sidebar_inbox_ids_by_account: { 2: [1] },
    };

    expect(filterSidebarInboxes(inboxes, uiSettings, 1)).toEqual(inboxes);
  });

  it('keeps only configured inboxes for the current account', () => {
    const uiSettings = {
      sidebar_inbox_ids_by_account: { 1: [4, 2, 9, 10] },
    };

    expect(filterSidebarInboxes(inboxes, uiSettings, 1)).toEqual([
      { id: 2, name: 'Info - EH' },
      { id: 4, name: 'Admin EH' },
      { id: 9, name: 'RingCentral SMS' },
      { id: 10, name: 'Scuba Shack' },
    ]);
  });

  it('treats a configured empty array as no visible sidebar inboxes', () => {
    const uiSettings = {
      sidebar_inbox_ids_by_account: { 1: [] },
    };

    expect(filterSidebarInboxes(inboxes, uiSettings, 1)).toEqual([]);
  });

  it('ignores unavailable inbox ids', () => {
    const uiSettings = {
      sidebar_inbox_ids_by_account: { 1: [2, 999] },
    };

    expect(filterSidebarInboxes(inboxes, uiSettings, 1)).toEqual([
      { id: 2, name: 'Info - EH' },
    ]);
  });

  it('matches ids serialized as strings', () => {
    const uiSettings = {
      sidebar_inbox_ids_by_account: { 1: ['2', '10'] },
    };

    expect(filterSidebarInboxes(inboxes, uiSettings, 1)).toEqual([
      { id: 2, name: 'Info - EH' },
      { id: 10, name: 'Scuba Shack' },
    ]);
  });

  it('does not coerce malformed values into inbox ids', () => {
    const uiSettings = {
      sidebar_inbox_ids_by_account: { 1: [true, ' 2 ', '0x2'] },
    };

    expect(filterSidebarInboxes(inboxes, uiSettings, 1)).toEqual([]);
  });
});
