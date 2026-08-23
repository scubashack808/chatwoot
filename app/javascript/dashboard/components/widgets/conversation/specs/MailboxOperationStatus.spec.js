import { shallowMount } from '@vue/test-utils';
import MailboxOperationStatus from '../MailboxOperationStatus.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params = {}) =>
      `${key}:${params.action || ''}:${params.succeeded || ''}:${
        params.total || ''
      }`,
  }),
}));

const mountComponent = ({ mailboxState = {}, mailboxOperation = {} } = {}) =>
  shallowMount(MailboxOperationStatus, {
    props: {
      mailboxState,
      mailboxOperation,
    },
  });

describe('MailboxOperationStatus', () => {
  it.each([
    ['pending', 'PENDING'],
    ['running', 'RUNNING'],
    ['partially_succeeded', 'PARTIAL'],
    ['failed', 'FAILED'],
    ['conflict', 'CONFLICT'],
  ])('renders %s operation status', (status, translationStatus) => {
    const wrapper = mountComponent({
      mailboxState: { state: 'inbox' },
      mailboxOperation: {
        action: 'archive',
        status,
        succeeded: 1,
        total: 2,
      },
    });

    expect(wrapper.text()).toContain(
      `CONVERSATION.MAILBOX.STATUS.${translationStatus}`
    );
  });

  it('renders mixed placement from server state', () => {
    const wrapper = mountComponent({
      mailboxState: { state: 'mixed' },
      mailboxOperation: { action: 'archive', status: 'succeeded' },
    });

    expect(wrapper.text()).toContain('CONVERSATION.MAILBOX.STATUS.MIXED');
  });

  it('renders nothing when mailbox keys are absent or state is settled', () => {
    const wrapper = mountComponent();

    expect(
      wrapper.find('[data-testid="mailbox-operation-status"]').exists()
    ).toBe(false);
  });
});
