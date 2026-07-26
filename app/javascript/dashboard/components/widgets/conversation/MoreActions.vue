<script setup>
import { computed, onUnmounted } from 'vue';
import { useToggle } from '@vueuse/core';
import { useStore } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { emitter } from 'shared/helpers/mitt';
import EmailTranscriptModal from './EmailTranscriptModal.vue';
import ResolveAction from '../../buttons/ResolveAction.vue';
import ButtonV4 from 'dashboard/components-next/button/Button.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';

import {
  CMD_MUTE_CONVERSATION,
  CMD_SEND_TRANSCRIPT,
  CMD_UNMUTE_CONVERSATION,
} from 'dashboard/helper/commandbar/events';
import {
  getMailboxActions,
  hasMailboxData,
} from 'dashboard/helper/mailboxOperations';

// No props needed as we're getting currentChat from the store directly
const store = useStore();
const { t } = useI18n();

const [showEmailActionsModal, toggleEmailModal] = useToggle(false);
const [showActionsDropdown, toggleDropdown] = useToggle(false);

const currentChat = computed(() => store.getters.getSelectedChat);
const mailboxActions = computed(() => {
  if (!hasMailboxData(currentChat.value)) return [];
  return getMailboxActions(
    currentChat.value.mailbox_state,
    currentChat.value.mailbox_operation
  );
});

const mailboxActionItems = computed(() => ({
  archive: {
    icon: 'i-lucide-archive',
    label: t('CONVERSATION.MAILBOX.ACTIONS.ARCHIVE'),
  },
  spam: {
    icon: 'i-lucide-triangle-alert',
    label: t('CONVERSATION.MAILBOX.ACTIONS.SPAM'),
  },
  trash: {
    icon: 'i-lucide-trash-2',
    label: t('CONVERSATION.MAILBOX.ACTIONS.TRASH'),
  },
  restore: {
    icon: 'i-lucide-undo-2',
    label: t('CONVERSATION.MAILBOX.ACTIONS.RESTORE'),
  },
}));

const actionMenuItems = computed(() => {
  const items = [];

  if (!currentChat.value.muted) {
    items.push({
      icon: 'i-lucide-volume-off',
      label: t('CONTACT_PANEL.MUTE_CONTACT'),
      action: 'mute',
      value: 'mute',
    });
  } else {
    items.push({
      icon: 'i-lucide-volume-1',
      label: t('CONTACT_PANEL.UNMUTE_CONTACT'),
      action: 'unmute',
      value: 'unmute',
    });
  }

  mailboxActions.value.forEach(action => {
    items.push({
      ...mailboxActionItems.value[action],
      action: `mailbox_${action}`,
      value: action,
    });
  });

  items.push({
    icon: 'i-lucide-share',
    label: t('CONTACT_PANEL.SEND_TRANSCRIPT'),
    action: 'send_transcript',
    value: 'send_transcript',
  });

  return items;
});

const mailboxActionErrorMessage = errorCode => {
  const messages = {
    mailbox_sync_not_active: t(
      'CONVERSATION.MAILBOX.ERRORS.MAILBOX_SYNC_NOT_ACTIVE'
    ),
    no_eligible_messages: t('CONVERSATION.MAILBOX.ERRORS.NO_ELIGIBLE_MESSAGES'),
    operation_in_progress: t(
      'CONVERSATION.MAILBOX.ERRORS.OPERATION_IN_PROGRESS'
    ),
    mailbox_actions_disabled: t(
      'CONVERSATION.MAILBOX.ERRORS.MAILBOX_ACTIONS_DISABLED'
    ),
  };
  return messages[errorCode] || t('CONVERSATION.MAILBOX.ERRORS.DEFAULT');
};

const performMailboxOperation = async action => {
  try {
    await store.dispatch('createMailboxOperation', {
      conversationId: currentChat.value.id,
      action,
    });
    useAlert(
      t('CONVERSATION.MAILBOX.REQUESTED', {
        action: mailboxActionItems.value[action].label,
      })
    );
  } catch (error) {
    const errorCode = error?.response?.data?.error_code;
    if (errorCode === 'operation_in_progress') {
      await store.dispatch('refetchMailboxOperation', currentChat.value.id);
    }
    useAlert(mailboxActionErrorMessage(errorCode));
  }
};

const handleActionClick = ({ action, value }) => {
  toggleDropdown(false);

  if (action.startsWith('mailbox_')) {
    performMailboxOperation(value);
  } else if (action === 'mute') {
    store.dispatch('muteConversation', currentChat.value.id);
    useAlert(t('CONTACT_PANEL.MUTED_SUCCESS'));
  } else if (action === 'unmute') {
    store.dispatch('unmuteConversation', currentChat.value.id);
    useAlert(t('CONTACT_PANEL.UNMUTED_SUCCESS'));
  } else if (action === 'send_transcript') {
    toggleEmailModal();
  }
};

// These functions are needed for the event listeners
const mute = () => {
  store.dispatch('muteConversation', currentChat.value.id);
  useAlert(t('CONTACT_PANEL.MUTED_SUCCESS'));
};

const unmute = () => {
  store.dispatch('unmuteConversation', currentChat.value.id);
  useAlert(t('CONTACT_PANEL.UNMUTED_SUCCESS'));
};

emitter.on(CMD_MUTE_CONVERSATION, mute);
emitter.on(CMD_UNMUTE_CONVERSATION, unmute);
emitter.on(CMD_SEND_TRANSCRIPT, toggleEmailModal);

onUnmounted(() => {
  emitter.off(CMD_MUTE_CONVERSATION, mute);
  emitter.off(CMD_UNMUTE_CONVERSATION, unmute);
  emitter.off(CMD_SEND_TRANSCRIPT, toggleEmailModal);
});
</script>

<template>
  <div class="relative flex items-center gap-2 actions--container">
    <ResolveAction
      :conversation-id="currentChat.id"
      :status="currentChat.status"
    />
    <div
      v-on-clickaway="() => toggleDropdown(false)"
      class="relative flex items-center group"
    >
      <ButtonV4
        v-tooltip="$t('CONVERSATION.HEADER.MORE_ACTIONS')"
        size="sm"
        variant="ghost"
        color="slate"
        icon="i-lucide-more-vertical"
        class="rounded-md group-hover:bg-n-alpha-2"
        @click="toggleDropdown()"
      />
      <DropdownMenu
        v-if="showActionsDropdown"
        :menu-items="actionMenuItems"
        class="mt-1 ltr:right-0 rtl:left-0 top-full"
        @action="handleActionClick"
      />
    </div>
    <EmailTranscriptModal
      v-if="showEmailActionsModal"
      :show="showEmailActionsModal"
      :current-chat="currentChat"
      @cancel="toggleEmailModal"
    />
  </div>
</template>
