import { mount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import campaigns from 'dashboard/store/modules/campaigns';
import CampaignsAPI from 'dashboard/api/campaigns';
import SMSCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/SMSCampaign/SMSCampaignDialog.vue';
import SMSCampaignsPage from '../SMSCampaignsPage.vue';

vi.mock('dashboard/api/campaigns', () => ({ default: { create: vi.fn() } }));
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
// VueUse's externalized dependency resolves a second Vue version in Vitest.
// Keep its toggle reactive in the same runtime as the actual page and dialog.
vi.mock('@vueuse/core', async importOriginal => {
  const actual = await importOriginal();
  const { ref } = await import('vue');
  return {
    ...actual,
    useToggle: (initial = false) => {
      const value = ref(initial);
      return [
        value,
        (next = !value.value) => {
          value.value = next;
        },
      ];
    },
  };
});

it('keeps the actual dialog mounted until success, displays the created campaign and reopens a fresh draft', async () => {
  let resolveCreate;
  let rejectCreate;
  CampaignsAPI.create.mockImplementation(
    () =>
      new Promise((resolve, reject) => {
        resolveCreate = resolve;
        rejectCreate = reject;
      })
  );
  const store = createStore({
    modules: {
      campaigns: {
        ...campaigns,
        state: {
          records: [],
          uiFlags: { isCreating: false, isFetching: false },
        },
      },
    },
    getters: {
      'labels/getLabels': () => [{ id: 3, title: 'Divers' }],
      'inboxes/getSMSInboxes': () => [{ id: 1, name: 'SMS' }],
    },
  });
  const wrapper = mount(SMSCampaignsPage, {
    attachTo: document.body,
    global: {
      plugins: [store],
      mocks: { $t: key => key },
      stubs: {
        ComboBox: {
          props: ['modelValue', 'options'],
          emits: ['update:modelValue'],
          template:
            '<select :value="modelValue" @change="$emit(\'update:modelValue\', Number($event.target.value))"><option /><option value="1">SMS</option></select>',
        },
        TagMultiSelectComboBox: {
          props: ['modelValue', 'options'],
          emits: ['update:modelValue'],
          template:
            '<select data-test="audience" multiple :value="modelValue" @change="$emit(\'update:modelValue\', [Number($event.target.value)])"><option value="3">Divers</option></select>',
        },
        CampaignList: {
          props: ['campaigns'],
          template:
            '<ul><li v-for="campaign in campaigns" :key="campaign.id">{{ campaign.title }}</li></ul>',
        },
        ConfirmDeleteCampaignDialog: true,
        SMSCampaignEmptyState: true,
      },
    },
  });
  try {
    await wrapper.find('header button').trigger('click');
    await flushPromises();
    const dialog = wrapper.findComponent(SMSCampaignDialog);
    await dialog.find('input').setValue('Dive trip reminder');
    await dialog
      .find('textarea')
      .setValue('Meet at the harbor entrance at 7am.');
    await dialog.find('#inbox').setValue('1');
    await dialog.find('[data-test="audience"]').setValue(['3']);
    await dialog
      .find('input[type="datetime-local"]')
      .setValue('2030-01-01T10:00');
    await dialog.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.create).toHaveBeenCalledTimes(1);
    expect(wrapper.findComponent(SMSCampaignDialog).element).toBe(
      dialog.element
    );
    expect(dialog.find('input').element.value).toBe('Dive trip reminder');
    rejectCreate(new Error('Synthetic failure'));
    await flushPromises();
    expect(wrapper.findComponent(SMSCampaignDialog).element).toBe(
      dialog.element
    );
    expect(dialog.find('textarea').element.value).toBe(
      'Meet at the harbor entrance at 7am.'
    );
    await dialog.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.create).toHaveBeenCalledTimes(2);
    expect(CampaignsAPI.create.mock.calls[1]).toEqual(
      CampaignsAPI.create.mock.calls[0]
    );
    resolveCreate({
      data: {
        ...CampaignsAPI.create.mock.calls[1][0],
        id: 99,
        campaign_type: 'one_off',
        inbox: { id: 1, channel_type: 'Channel::Sms' },
      },
    });
    await flushPromises();
    expect(wrapper.findComponent(SMSCampaignDialog).exists()).toBe(false);
    expect(dialog.emitted('close')).toHaveLength(1);
    expect(wrapper.find('main li').text()).toBe('Dive trip reminder');
    await wrapper.find('header button').trigger('click');
    const freshDialog = wrapper.findComponent(SMSCampaignDialog);
    expect(freshDialog.element).not.toBe(dialog.element);
    expect(freshDialog.find('input').element.value).toBe('');
    expect(freshDialog.find('textarea').element.value).toBe('');
    expect(freshDialog.find('#inbox').element.value).toBe('');
    expect(
      freshDialog.find('[data-test="audience"]').element.selectedOptions
    ).toHaveLength(0);
    expect(freshDialog.find('input[type="datetime-local"]').element.value).toBe(
      ''
    );
    await freshDialog.find('button[type="button"]').trigger('click');
    expect(wrapper.findComponent(SMSCampaignDialog).exists()).toBe(false);
  } finally {
    wrapper.unmount();
  }
});
