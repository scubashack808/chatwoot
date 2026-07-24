<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import SelectInput from 'dashboard/components-next/select/Select.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import InboxesAPI from 'dashboard/api/inboxes';

const ROLES = ['archive', 'trash', 'spam', 'sent'];

export default {
  components: {
    SettingsFieldSection,
    SelectInput,
    NextButton,
    Spinner,
  },
  props: {
    inbox: {
      type: Object,
      default: () => ({}),
    },
  },
  data() {
    return {
      roles: ROLES,
      mode: 'off',
      sentMode: 'provider_managed',
      overrides: {},
      discovery: null,
      isDiscovering: false,
      discoveryError: '',
    };
  },
  computed: {
    ...mapGetters({ uiFlags: 'inboxes/getUIFlags' }),
    modeOptions() {
      return [
        {
          value: 'off',
          label: this.$t('INBOX_MGMT.MAILBOX_SYNC.MODE.OPTIONS.OFF'),
        },
        {
          value: 'observe',
          label: this.$t('INBOX_MGMT.MAILBOX_SYNC.MODE.OPTIONS.OBSERVE'),
        },
        {
          value: 'active',
          label: this.$t('INBOX_MGMT.MAILBOX_SYNC.MODE.OPTIONS.ACTIVE'),
        },
      ];
    },
    sentModeOptions() {
      return [
        {
          value: 'provider_managed',
          label: this.$t(
            'INBOX_MGMT.MAILBOX_SYNC.SENT_MODE.OPTIONS.PROVIDER_MANAGED'
          ),
        },
        {
          value: 'append',
          label: this.$t('INBOX_MGMT.MAILBOX_SYNC.SENT_MODE.OPTIONS.APPEND'),
        },
        {
          value: 'disabled',
          label: this.$t('INBOX_MGMT.MAILBOX_SYNC.SENT_MODE.OPTIONS.DISABLED'),
        },
      ];
    },
    roleLabels() {
      return {
        archive: this.$t('INBOX_MGMT.MAILBOX_SYNC.FOLDERS.ROLES.ARCHIVE'),
        trash: this.$t('INBOX_MGMT.MAILBOX_SYNC.FOLDERS.ROLES.TRASH'),
        spam: this.$t('INBOX_MGMT.MAILBOX_SYNC.FOLDERS.ROLES.SPAM'),
        sent: this.$t('INBOX_MGMT.MAILBOX_SYNC.FOLDERS.ROLES.SENT'),
      };
    },
    statusLabels() {
      return {
        discovered: this.$t(
          'INBOX_MGMT.MAILBOX_SYNC.FOLDERS.STATUS.DISCOVERED'
        ),
        ambiguous: this.$t('INBOX_MGMT.MAILBOX_SYNC.FOLDERS.STATUS.AMBIGUOUS'),
        unavailable: this.$t(
          'INBOX_MGMT.MAILBOX_SYNC.FOLDERS.STATUS.UNAVAILABLE'
        ),
        overridden: this.$t(
          'INBOX_MGMT.MAILBOX_SYNC.FOLDERS.STATUS.OVERRIDDEN'
        ),
        invalid_override: this.$t(
          'INBOX_MGMT.MAILBOX_SYNC.FOLDERS.STATUS.INVALID_OVERRIDE'
        ),
      };
    },
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
      const config = this.inbox.mailbox_sync_config || {};
      this.mode = config.mode || 'off';
      this.sentMode = config.sent_mode || 'provider_managed';
      this.overrides = { ...(config.folder_overrides || {}) };
    },
    roleResult(role) {
      return this.discovery?.roles?.[role] || null;
    },
    // Every listed folder is offered, not only the ones carrying a special-use attribute, because
    // an override exists precisely for the case where discovery found nothing usable.
    folderOptions() {
      const folders = this.discovery?.folders || [];
      const options = folders
        .filter(folder => !(folder.attributes || []).includes('noselect'))
        .map(folder => ({ value: folder.name, label: folder.name }));
      return [
        {
          value: '',
          label: this.$t('INBOX_MGMT.MAILBOX_SYNC.FOLDERS.NO_OVERRIDE'),
        },
        ...options,
      ];
    },
    statusLabel(role) {
      const result = this.roleResult(role);
      if (!result) return '';
      return this.statusLabels[result.status] || '';
    },
    statusClass(role) {
      const result = this.roleResult(role);
      if (!result) return 'text-n-slate-11';
      return result.available ? 'text-n-teal-11' : 'text-n-amber-11';
    },
    async discoverFolders() {
      this.isDiscovering = true;
      this.discoveryError = '';
      try {
        const response = await InboxesAPI.discoverMailboxFolders(this.inbox.id);
        this.discovery = response.data;
      } catch (error) {
        this.discovery = null;
        this.discoveryError =
          error?.response?.data?.error ||
          this.$t('INBOX_MGMT.MAILBOX_SYNC.FOLDERS.DISCOVERY_ERROR');
      } finally {
        this.isDiscovering = false;
      }
    },
    buildOverrides() {
      return this.roles.reduce((acc, role) => {
        if (this.overrides[role]) acc[role] = this.overrides[role];
        return acc;
      }, {});
    },
    async updateInbox() {
      try {
        await this.$store.dispatch('inboxes/updateInboxIMAP', {
          id: this.inbox.id,
          formData: false,
          channel: {
            mailbox_sync_config: {
              mode: this.mode,
              sent_mode: this.sentMode,
              folder_overrides: this.buildOverrides(),
            },
          },
        });
        useAlert(this.$t('INBOX_MGMT.MAILBOX_SYNC.EDIT.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(
          error.message || this.$t('INBOX_MGMT.MAILBOX_SYNC.EDIT.ERROR_MESSAGE')
        );
      }
    },
  },
};
</script>

<template>
  <SettingsFieldSection
    :label="$t('INBOX_MGMT.MAILBOX_SYNC.TITLE')"
    :help-text="$t('INBOX_MGMT.MAILBOX_SYNC.NOTE_TEXT')"
    class="[&>div]:!items-start [&>div>label]:mt-1 mb-4"
  >
    <form @submit.prevent="updateInbox">
      <div class="mb-6">
        <SelectInput
          v-model="mode"
          class="w-full"
          :options="modeOptions"
          :label="$t('INBOX_MGMT.MAILBOX_SYNC.MODE.LABEL')"
        />
        <p class="text-label-small text-n-slate-11 mt-1.5">
          {{ $t('INBOX_MGMT.MAILBOX_SYNC.MODE.HELP_TEXT') }}
        </p>
      </div>

      <div class="mb-6">
        <SelectInput
          v-model="sentMode"
          class="w-full"
          :options="sentModeOptions"
          :label="$t('INBOX_MGMT.MAILBOX_SYNC.SENT_MODE.LABEL')"
        />
        <p class="text-label-small text-n-slate-11 mt-1.5">
          {{ $t('INBOX_MGMT.MAILBOX_SYNC.SENT_MODE.HELP_TEXT') }}
        </p>
      </div>

      <div class="mb-6">
        <div class="flex items-center gap-3 mb-2">
          <NextButton
            type="button"
            sm
            faded
            slate
            :label="$t('INBOX_MGMT.MAILBOX_SYNC.FOLDERS.DISCOVER')"
            :disabled="isDiscovering"
            @click="discoverFolders"
          />
          <Spinner v-if="isDiscovering" class="size-4 text-n-slate-11" />
        </div>

        <p
          v-if="discoveryError"
          class="py-2 px-3 bg-n-amber-3 outline-n-amber-4 text-n-amber-11 outline outline-1 -outline-offset-1 rounded-xl text-body-para"
        >
          {{ discoveryError }}
        </p>

        <p
          v-else-if="!discovery && !isDiscovering"
          class="text-label-small text-n-slate-11"
        >
          {{ $t('INBOX_MGMT.MAILBOX_SYNC.FOLDERS.NOT_DISCOVERED_YET') }}
        </p>

        <div v-else-if="discovery" class="flex flex-col gap-4">
          <div v-for="role in roles" :key="role" class="flex flex-col gap-1">
            <div class="flex items-center gap-2">
              <span class="text-heading-3 text-n-slate-12">
                {{ roleLabels[role] }}
              </span>
              <span
                class="inline-flex items-center gap-1.5 px-2 py-0.5 min-h-6 text-label-small rounded-md bg-n-alpha-2"
                :class="statusClass(role)"
              >
                {{ statusLabel(role) }}
              </span>
            </div>

            <p class="text-label-small text-n-slate-11">
              <template v-if="roleResult(role)?.selected">
                {{
                  $t('INBOX_MGMT.MAILBOX_SYNC.FOLDERS.USING', {
                    folder: roleResult(role).selected,
                  })
                }}
              </template>
              <template v-else-if="roleResult(role)?.candidates?.length">
                {{
                  $t('INBOX_MGMT.MAILBOX_SYNC.FOLDERS.AMBIGUOUS_HELP', {
                    folders: roleResult(role).candidates.join(', '),
                  })
                }}
              </template>
              <template v-else>
                {{ $t('INBOX_MGMT.MAILBOX_SYNC.FOLDERS.UNAVAILABLE_HELP') }}
              </template>
            </p>

            <SelectInput
              v-model="overrides[role]"
              class="w-full"
              :options="folderOptions"
              :placeholder="$t('INBOX_MGMT.MAILBOX_SYNC.FOLDERS.NO_OVERRIDE')"
            />
          </div>
        </div>
      </div>

      <NextButton
        type="submit"
        :label="$t('INBOX_MGMT.MAILBOX_SYNC.UPDATE')"
        :is-loading="uiFlags.isUpdatingIMAP"
        :disabled="uiFlags.isUpdatingIMAP"
      />
    </form>
  </SettingsFieldSection>
</template>
