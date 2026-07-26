import {
  MAILBOX_ROLES,
  getMailboxActions,
  getMailboxDisplayStatus,
  hasMailboxData,
  isEmailHardDeleteError,
  mailboxStateIncludesRole,
} from '../mailboxOperations';

describe('mailboxOperations', () => {
  describe('MAILBOX_ROLES', () => {
    it('exposes only the server-backed views and retires Drafts', () => {
      expect(MAILBOX_ROLES).toEqual(['inbox', 'archive', 'spam', 'trash']);
      expect(MAILBOX_ROLES).not.toContain('drafts');
    });
  });

  describe('hasMailboxData', () => {
    it('uses key presence as the feature and authorization signal', () => {
      expect(hasMailboxData({ mailbox_state: null })).toBe(true);
      expect(hasMailboxData({})).toBe(false);
      expect(hasMailboxData(null)).toBe(false);
    });
  });

  describe('getMailboxActions', () => {
    it('offers server-backed actions from server-derived inbox state', () => {
      expect(getMailboxActions({ state: 'inbox' })).toEqual([
        'archive',
        'spam',
        'trash',
      ]);
    });

    it('offers Restore and excludes the action matching the current state', () => {
      expect(getMailboxActions({ state: 'trash', roles: ['trash'] })).toEqual([
        'restore',
        'spam',
      ]);
    });

    it('disables actions while an operation is nonterminal', () => {
      expect(
        getMailboxActions(
          { state: 'inbox' },
          { action: 'archive', status: 'running' }
        )
      ).toEqual([]);
    });
  });

  describe('getMailboxDisplayStatus', () => {
    it.each([
      ['pending', 'pending'],
      ['running', 'running'],
      ['partially_succeeded', 'partial'],
      ['failed', 'failed'],
      ['conflict', 'conflict'],
    ])('maps %s operation state to %s', (operationStatus, displayStatus) => {
      expect(
        getMailboxDisplayStatus({ state: 'inbox' }, { status: operationStatus })
      ).toBe(displayStatus);
    });

    it('renders mixed server state after a successful operation', () => {
      expect(
        getMailboxDisplayStatus({ state: 'mixed' }, { status: 'succeeded' })
      ).toBe('mixed');
    });
  });

  describe('isEmailHardDeleteError', () => {
    it('recognizes the guarded 422 response as a move-to-Trash path', () => {
      expect(
        isEmailHardDeleteError({
          response: {
            status: 422,
            data: {
              message:
                'Email conversations cannot be permanently deleted in Chatwoot. Move them to Trash so they remain restorable.',
            },
          },
        })
      ).toBe(true);
    });

    it('does not reinterpret a non-422 delete failure', () => {
      expect(
        isEmailHardDeleteError({
          response: { status: 500, data: { error: 'Server error' } },
        })
      ).toBe(false);
    });
  });

  describe('mailboxStateIncludesRole', () => {
    it('uses the server-derived roles to determine view membership', () => {
      const mailboxState = {
        state: 'mixed',
        roles: ['inbox', 'archive'],
        untracked_count: 0,
      };

      expect(mailboxStateIncludesRole(mailboxState, 'inbox')).toBe(true);
      expect(mailboxStateIncludesRole(mailboxState, 'archive')).toBe(true);
      expect(mailboxStateIncludesRole(mailboxState, 'trash')).toBe(false);
    });

    it('keeps untracked mail in the server-defined inbox view', () => {
      expect(
        mailboxStateIncludesRole(
          { state: 'mixed', roles: ['archive'], untracked_count: 1 },
          'inbox'
        )
      ).toBe(true);
    });
  });
});
