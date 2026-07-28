<script>
import { useAlert } from 'dashboard/composables';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import TagInput from 'dashboard/components-next/taginput/TagInput.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    SettingsFieldSection,
    TagInput,
    NextButton,
  },
  props: {
    inbox: {
      type: Object,
      default: () => ({}),
    },
  },
  data() {
    return {
      aliases: [],
      isUpdating: false,
    };
  },
  watch: {
    inbox() {
      this.setDefaults();
    },
  },
  mounted() {
    this.setDefaults();
  },
  methods: {
    setDefaults() {
      this.aliases = [...(this.inbox.aliases || [])];
    },
    // Uniqueness across inboxes is enforced by the server, so a collision surfaces here as the
    // server's own message rather than being guessed at in the browser.
    async updateAliases() {
      this.isUpdating = true;
      try {
        await this.$store.dispatch('inboxes/updateInbox', {
          id: this.inbox.id,
          formData: false,
          channel: { aliases: this.aliases },
        });
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(
          error?.message || this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE')
        );
        this.setDefaults();
      } finally {
        this.isUpdating = false;
      }
    },
  },
};
</script>

<template>
  <SettingsFieldSection
    :label="$t('INBOX_MGMT.SETTINGS_POPUP.EMAIL_ALIASES_TITLE')"
    :help-text="$t('INBOX_MGMT.SETTINGS_POPUP.EMAIL_ALIASES_SUB_TEXT')"
  >
    <div class="flex flex-col items-start gap-3">
      <TagInput
        v-model="aliases"
        type="email"
        allow-create
        :placeholder="$t('INBOX_MGMT.SETTINGS_POPUP.EMAIL_ALIASES_PLACEHOLDER')"
        class="w-full"
      />
      <NextButton
        :is-loading="isUpdating"
        :disabled="isUpdating"
        @click="updateAliases"
      >
        {{ $t('INBOX_MGMT.SETTINGS_POPUP.EMAIL_ALIASES_SAVE') }}
      </NextButton>
    </div>
  </SettingsFieldSection>
</template>
