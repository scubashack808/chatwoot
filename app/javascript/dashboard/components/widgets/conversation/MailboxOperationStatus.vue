<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { getMailboxDisplayStatus } from 'dashboard/helper/mailboxOperations';

const props = defineProps({
  mailboxState: { type: Object, default: null },
  mailboxOperation: { type: Object, default: null },
});
const { t } = useI18n();

const displayStatus = computed(() =>
  getMailboxDisplayStatus(props.mailboxState, props.mailboxOperation)
);

const actionLabel = computed(() => {
  const labels = {
    archive: t('CONVERSATION.MAILBOX.ACTIONS.ARCHIVE'),
    spam: t('CONVERSATION.MAILBOX.ACTIONS.SPAM'),
    trash: t('CONVERSATION.MAILBOX.ACTIONS.TRASH'),
    restore: t('CONVERSATION.MAILBOX.ACTIONS.RESTORE'),
  };
  return labels[props.mailboxOperation?.action] || '';
});

const statusLabel = computed(() => {
  const params = {
    action: actionLabel.value,
    succeeded: props.mailboxOperation?.succeeded,
    total: props.mailboxOperation?.total,
  };
  const labels = {
    pending: t('CONVERSATION.MAILBOX.STATUS.PENDING', params),
    running: t('CONVERSATION.MAILBOX.STATUS.RUNNING', params),
    partial: t('CONVERSATION.MAILBOX.STATUS.PARTIAL', params),
    failed: t('CONVERSATION.MAILBOX.STATUS.FAILED', params),
    conflict: t('CONVERSATION.MAILBOX.STATUS.CONFLICT', params),
    mixed: t('CONVERSATION.MAILBOX.STATUS.MIXED'),
  };
  return labels[displayStatus.value] || '';
});

const statusClasses = computed(() => {
  const classes = {
    pending: 'bg-n-alpha-2 text-n-slate-11',
    running: 'bg-n-blue-3 text-n-blue-11',
    partial: 'bg-n-amber-3 text-n-amber-11',
    failed: 'bg-n-ruby-3 text-n-ruby-11',
    conflict: 'bg-n-amber-3 text-n-amber-11',
    mixed: 'bg-n-iris-3 text-n-iris-11',
  };
  return classes[displayStatus.value];
});
</script>

<template>
  <span
    v-if="displayStatus"
    data-testid="mailbox-operation-status"
    class="inline-flex items-center max-w-full px-1.5 py-0.5 text-xxs font-medium leading-4 rounded truncate"
    :class="statusClasses"
  >
    {{ statusLabel }}
  </span>
  <span v-else class="hidden" aria-hidden="true" />
</template>
