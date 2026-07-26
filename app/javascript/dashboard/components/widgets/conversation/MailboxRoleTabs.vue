<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { MAILBOX_ROLES } from 'dashboard/helper/mailboxOperations';

defineProps({
  inboxId: { type: [String, Number], required: true },
  activeRole: { type: String, default: 'inbox' },
});
const { t } = useI18n();

const roleLabels = computed(() => ({
  inbox: t('CHAT_LIST.MAILBOX_ROLES.INBOX'),
  archive: t('CHAT_LIST.MAILBOX_ROLES.ARCHIVE'),
  spam: t('CHAT_LIST.MAILBOX_ROLES.SPAM'),
  trash: t('CHAT_LIST.MAILBOX_ROLES.TRASH'),
}));

const roleRoute = (inboxId, role) => {
  if (role === 'inbox') {
    return {
      name: 'inbox_dashboard',
      params: { inbox_id: inboxId },
    };
  }

  return {
    name: 'inbox_mailbox_role',
    params: { inbox_id: inboxId, mailbox_role: role },
  };
};
</script>

<template>
  <nav
    class="flex items-center gap-1 px-3 py-2 overflow-x-auto border-b border-n-weak no-scrollbar"
    :aria-label="$t('CHAT_LIST.MAILBOX_ROLES.LABEL')"
  >
    <RouterLink
      v-for="role in MAILBOX_ROLES"
      :key="role"
      :to="roleRoute(inboxId, role)"
      class="px-2 py-1 text-xs font-medium rounded-md whitespace-nowrap"
      :class="
        activeRole === role
          ? 'text-n-slate-12 bg-n-alpha-2'
          : 'text-n-slate-11 hover:bg-n-alpha-1'
      "
      :aria-current="activeRole === role ? 'page' : undefined"
    >
      {{ roleLabels[role] }}
    </RouterLink>
  </nav>
</template>
