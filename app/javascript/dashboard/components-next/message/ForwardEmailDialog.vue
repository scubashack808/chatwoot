<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { getFileInfo } from '@chatwoot/utils';
import { useAlert } from 'dashboard/composables';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { createPendingMessage } from 'dashboard/helper/commons';
import { validEmailsByComma } from 'dashboard/components/widgets/conversation/helpers/emailHeadHelper';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

const props = defineProps({
  messageId: { type: Number, required: true },
  conversationId: { type: Number, required: true },
  email: { type: Object, default: () => ({}) },
  attachments: { type: Array, default: () => [] },
});

const NOTE_MAX_LENGTH = 10000;

const { t } = useI18n();
const store = useStore();
const currentUser = useMapGetter('getCurrentUser');

const dialogRef = ref(null);
const toEmails = ref('');
const ccEmails = ref('');
const note = ref('');
const showErrors = ref(false);
const isSending = ref(false);

const isToValid = computed(
  () => !!toEmails.value.trim() && validEmailsByComma(toEmails.value)
);
const isCcValid = computed(() => validEmailsByComma(ccEmails.value));

const originalFrom = computed(() => [props.email?.from].flat().join(', '));
const originalSubject = computed(() => props.email?.subject || '');
const originalDate = computed(() => props.email?.date || '');
const attachmentNames = computed(() =>
  props.attachments.map(
    attachment => getFileInfo(attachment.dataUrl || '').name
  )
);

const reset = () => {
  toEmails.value = '';
  ccEmails.value = '';
  note.value = '';
  showErrors.value = false;
  isSending.value = false;
};

const open = () => {
  reset();
  dialogRef.value?.open();
};

const forward = async () => {
  showErrors.value = true;
  if (!isToValid.value || !isCcValid.value || isSending.value) return;

  isSending.value = true;
  const pendingMessage = createPendingMessage({
    conversationId: props.conversationId,
    message: note.value,
    private: false,
    toEmails: toEmails.value.replace(/\s+/g, ''),
    ccEmails: ccEmails.value.replace(/\s+/g, ''),
    contentAttributes: { forwarded_message_id: props.messageId },
    sender: {
      name: currentUser.value.name,
      thumbnail: currentUser.value.avatar_url,
    },
  });

  try {
    await store.dispatch('sendMessageWithData', pendingMessage);
    emitter.emit(BUS_EVENTS.SCROLL_TO_MESSAGE);
    useAlert(t('FORWARD_EMAIL.SUCCESS_MESSAGE'));
    dialogRef.value?.close();
  } catch (error) {
    useAlert(error?.response?.data?.error || t('FORWARD_EMAIL.ERROR_MESSAGE'));
  } finally {
    isSending.value = false;
  }
};

defineExpose({ open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="2xl"
    :title="t('FORWARD_EMAIL.TITLE')"
    :description="t('FORWARD_EMAIL.DESCRIPTION')"
    :confirm-button-label="t('FORWARD_EMAIL.SEND')"
    :cancel-button-label="t('FORWARD_EMAIL.CANCEL')"
    :is-loading="isSending"
    :disable-confirm-button="isSending"
    @confirm="forward"
  >
    <div class="flex flex-col gap-4">
      <Input
        v-model="toEmails"
        data-testid="forward-email-to"
        :label="t('FORWARD_EMAIL.TO.LABEL')"
        :placeholder="t('FORWARD_EMAIL.TO.PLACEHOLDER')"
        :message="showErrors && !isToValid ? t('FORWARD_EMAIL.TO.ERROR') : ''"
        :message-type="showErrors && !isToValid ? 'error' : 'info'"
        autofocus
      />
      <Input
        v-model="ccEmails"
        data-testid="forward-email-cc"
        :label="t('FORWARD_EMAIL.CC.LABEL')"
        :placeholder="t('FORWARD_EMAIL.CC.PLACEHOLDER')"
        :message="showErrors && !isCcValid ? t('FORWARD_EMAIL.CC.ERROR') : ''"
        :message-type="showErrors && !isCcValid ? 'error' : 'info'"
      />
      <TextArea
        v-model="note"
        data-testid="forward-email-note"
        :label="t('FORWARD_EMAIL.NOTE.LABEL')"
        :placeholder="t('FORWARD_EMAIL.NOTE.PLACEHOLDER')"
        :max-length="NOTE_MAX_LENGTH"
        auto-height
        resize
      />
      <div
        data-testid="forward-email-original"
        class="flex flex-col gap-1 p-3 text-sm rounded-lg bg-n-alpha-black2 text-n-slate-11"
      >
        <span class="font-medium text-n-slate-12">
          {{ t('FORWARD_EMAIL.FORWARDED_MESSAGE') }}
        </span>
        <span v-if="originalFrom">
          {{ t('FORWARD_EMAIL.FROM', { value: originalFrom }) }}
        </span>
        <span v-if="originalDate">
          {{ t('FORWARD_EMAIL.DATE', { value: originalDate }) }}
        </span>
        <span v-if="originalSubject">
          {{ t('FORWARD_EMAIL.SUBJECT', { value: originalSubject }) }}
        </span>
        <div v-if="attachmentNames.length" class="flex flex-wrap gap-2 pt-1">
          <span
            v-for="name in attachmentNames"
            :key="name"
            class="inline-flex items-center gap-1 px-2 py-0.5 rounded-md bg-n-alpha-2 text-n-slate-12"
          >
            <Icon icon="i-lucide-paperclip" class="size-3.5" />
            {{ name }}
          </span>
        </div>
      </div>
    </div>
  </Dialog>
</template>
