import { CONVERSATION_PRIORITY_ORDER } from 'shared/constants/messages';

// Whether a message already held in the conversation is the same message as one
// arriving for it. Sending gives a single message two identities in turn: the
// pending object carries a client uuid as both id and echo_id, the server response
// carries the real id and echoes echo_id back, and later websocket frames carry the
// real id alone, since echo_id is only ever set on the object that created it and
// is never persisted. No single field identifies a message across all three, so
// this relation is what "the same message" means. Directional: the held message
// first, the arriving one second.
export const isSameMessage = (held, arriving) =>
  held.id === arriving.id || held.id === arriving.echo_id;

export const findPendingMessageIndex = (chat, message) =>
  chat.messages.findIndex(m => isSameMessage(m, message));

export const filterByStatus = (chatStatus, filterStatus) =>
  filterStatus === 'all' ? true : chatStatus === filterStatus;

export const filterByInbox = (shouldFilter, inboxId, chatInboxId) => {
  const isOnInbox = Number(inboxId) === chatInboxId;
  return inboxId ? isOnInbox && shouldFilter : shouldFilter;
};

export const filterByTeam = (shouldFilter, teamId, chatTeamId) => {
  const isOnTeam = Number(teamId) === chatTeamId;
  return teamId ? isOnTeam && shouldFilter : shouldFilter;
};

export const filterByLabel = (shouldFilter, labels, chatLabels) => {
  const isOnLabel = labels.every(label => chatLabels.includes(label));
  return labels.length ? isOnLabel && shouldFilter : shouldFilter;
};
export const filterByUnattended = (
  shouldFilter,
  conversationType,
  firstReplyOn,
  waitingSince
) => {
  return conversationType === 'unattended'
    ? (!firstReplyOn || !!waitingSince) && shouldFilter
    : shouldFilter;
};

export const applyPageFilters = (conversation, filters) => {
  const { inboxId, status, labels = [], teamId, conversationType } = filters;
  const {
    status: chatStatus,
    inbox_id: chatInboxId,
    labels: chatLabels = [],
    meta = {},
    first_reply_created_at: firstReplyOn,
    waiting_since: waitingSince,
  } = conversation;
  const team = meta.team || {};
  const { id: chatTeamId } = team;

  let shouldFilter = filterByStatus(chatStatus, status);
  shouldFilter = filterByInbox(shouldFilter, inboxId, chatInboxId);
  shouldFilter = filterByTeam(shouldFilter, teamId, chatTeamId);
  shouldFilter = filterByLabel(shouldFilter, labels, chatLabels);
  shouldFilter = filterByUnattended(
    shouldFilter,
    conversationType,
    firstReplyOn,
    waitingSince
  );

  return shouldFilter;
};

/**
 * Filters conversations based on user role and permissions
 *
 * @param {Object} conversation - The conversation object to check permissions for
 * @param {string} role - The user's role (administrator, agent, etc.)
 * @param {Array<string>} permissions - List of permission strings the user has
 * @param {number|string} currentUserId - The ID of the current user
 * @returns {boolean} - Whether the user has permissions to access this conversation
 */
export const applyRoleFilter = (
  conversation,
  role,
  permissions,
  currentUserId
) => {
  // the role === "agent" check is typically not correct on it's own
  // the backend handles this by checking the custom_role_id at the user model
  // here however, the `getUserRole` returns "custom_role" if the id is present,
  // so we can check the role === "agent" directly
  if (['administrator', 'agent'].includes(role)) {
    return true;
  }

  // Check for full conversation management permission
  if (permissions.includes('conversation_manage')) {
    return true;
  }

  const conversationAssignee = conversation.meta.assignee;
  const isUnassigned = !conversationAssignee;
  const isAssignedToUser = conversationAssignee?.id === currentUserId;

  // Check unassigned management permission
  if (permissions.includes('conversation_unassigned_manage')) {
    return isUnassigned || isAssignedToUser;
  }

  // Check participating conversation management permission
  if (permissions.includes('conversation_participating_manage')) {
    return isAssignedToUser;
  }

  return false;
};

const SORT_OPTIONS = {
  last_activity_at_asc: ['sortOnLastActivityAt', 'asc'],
  last_activity_at_desc: ['sortOnLastActivityAt', 'desc'],
  created_at_asc: ['sortOnCreatedAt', 'asc'],
  created_at_desc: ['sortOnCreatedAt', 'desc'],
  priority_asc: ['sortOnPriority', 'asc'],
  priority_desc: ['sortOnPriority', 'desc'],
  waiting_since_asc: ['sortOnWaitingSince', 'asc'],
  waiting_since_desc: ['sortOnWaitingSince', 'desc'],
  priority_desc_created_at_asc: ['sortOnPriorityCreatedAt', 'desc'],
};
const sortAscending = (valueA, valueB) => valueA - valueB;
const sortDescending = (valueA, valueB) => valueB - valueA;

const getSortOrderFunction = sortOrder =>
  sortOrder === 'asc' ? sortAscending : sortDescending;

const sortConfig = {
  sortOnLastActivityAt: (a, b, sortDirection) =>
    getSortOrderFunction(sortDirection)(a.last_activity_at, b.last_activity_at),

  sortOnCreatedAt: (a, b, sortDirection) =>
    getSortOrderFunction(sortDirection)(a.created_at, b.created_at),

  sortOnPriority: (a, b, sortDirection) => {
    const DEFAULT_FOR_NULL = sortDirection === 'asc' ? 5 : 0;

    const p1 = CONVERSATION_PRIORITY_ORDER[a.priority] || DEFAULT_FOR_NULL;
    const p2 = CONVERSATION_PRIORITY_ORDER[b.priority] || DEFAULT_FOR_NULL;

    return getSortOrderFunction(sortDirection)(p1, p2);
  },

  sortOnPriorityCreatedAt: (a, b) => {
    const DEFAULT_FOR_NULL = 0;
    const p1 = CONVERSATION_PRIORITY_ORDER[a.priority] || DEFAULT_FOR_NULL;
    const p2 = CONVERSATION_PRIORITY_ORDER[b.priority] || DEFAULT_FOR_NULL;
    if (p1 !== p2) return p2 - p1;
    return a.created_at - b.created_at;
  },

  sortOnWaitingSince: (a, b, sortDirection) => {
    const sortFunc = getSortOrderFunction(sortDirection);
    if (!a.waiting_since || !b.waiting_since) {
      if (!a.waiting_since && !b.waiting_since) {
        return sortFunc(a.created_at, b.created_at);
      }
      return sortFunc(a.waiting_since ? 0 : 1, b.waiting_since ? 0 : 1);
    }

    return sortFunc(a.waiting_since, b.waiting_since);
  },
};

export const sortComparator = (a, b, sortKey) => {
  const [sortMethod, sortDirection] =
    SORT_OPTIONS[sortKey] || SORT_OPTIONS.last_activity_at_desc;
  return sortConfig[sortMethod](a, b, sortDirection);
};
