export const SIDEBAR_INBOX_IDS_BY_ACCOUNT_KEY = 'sidebar_inbox_ids_by_account';

export const filterSidebarInboxes = (inboxes, uiSettings, accountId) => {
  const inboxIds =
    uiSettings?.[SIDEBAR_INBOX_IDS_BY_ACCOUNT_KEY]?.[String(accountId)];

  if (!Array.isArray(inboxIds)) return inboxes;

  const visibleInboxIds = new Set(inboxIds.map(String));
  return inboxes.filter(inbox => visibleInboxIds.has(String(inbox.id)));
};
