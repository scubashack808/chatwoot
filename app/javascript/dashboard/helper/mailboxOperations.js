export const MAILBOX_ROLES = Object.freeze([
  'inbox',
  'sent',
  'archive',
  'spam',
  'trash',
]);

const NONTERMINAL_OPERATION_STATUSES = ['pending', 'running'];
const TERMINAL_OPERATION_STATUSES = [
  'succeeded',
  'partially_succeeded',
  'failed',
  'conflict',
];

export const hasMailboxData = conversation =>
  Boolean(
    conversation &&
      Object.prototype.hasOwnProperty.call(conversation, 'mailbox_state')
  );

export const isMailboxOperationInProgress = operation =>
  NONTERMINAL_OPERATION_STATUSES.includes(operation?.status);

export const isMailboxOperationTerminal = operation =>
  TERMINAL_OPERATION_STATUSES.includes(operation?.status);

export const mailboxStateIncludesRole = (mailboxState, mailboxRole) => {
  const roles = mailboxState?.roles || [];
  // Sent has no mailbox_state fact behind it. Imap::ConversationMailboxState derives roles from
  // INCOMING messages, and its vocabulary is inbox/archive/trash/spam, so roles never contains
  // 'sent'. Falling through to roles.includes would make this permanently false for the Sent view,
  // and ChatList's "is this conversation still in the view I am looking at" check would redirect
  // the agent out of an open conversation on every terminal mailbox operation. Mailbox operations
  // move incoming mail; they never change whether a conversation has an outgoing message.
  if (mailboxRole === 'sent') {
    return true;
  }
  if (mailboxRole === 'inbox') {
    return (
      mailboxState?.state === 'inbox' ||
      roles.includes('inbox') ||
      mailboxState?.untracked_count > 0
    );
  }
  return roles.includes(mailboxRole);
};

export const getMailboxActions = (mailboxState, mailboxOperation) => {
  if (!mailboxState?.state || isMailboxOperationInProgress(mailboxOperation)) {
    return [];
  }

  const actions = [];
  if (
    ['archive', 'spam', 'trash'].some(role =>
      mailboxStateIncludesRole(mailboxState, role)
    )
  ) {
    actions.push('restore');
  }
  if (mailboxStateIncludesRole(mailboxState, 'inbox')) actions.push('archive');
  if (mailboxState.state !== 'spam') actions.push('spam');
  if (mailboxState.state !== 'trash') actions.push('trash');
  return actions;
};

export const getMailboxDisplayStatus = (
  mailboxState,
  mailboxOperation = {}
) => {
  const operationStatusMap = {
    pending: 'pending',
    running: 'running',
    partially_succeeded: 'partial',
    failed: 'failed',
    conflict: 'conflict',
  };
  const operationStatus = operationStatusMap[mailboxOperation?.status];
  if (operationStatus) return operationStatus;
  return mailboxState?.state === 'mixed' ? 'mixed' : null;
};

export const isEmailHardDeleteError = error => error?.response?.status === 422;
