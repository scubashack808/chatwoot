import { mount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import CampaignsAPI from 'dashboard/api/campaigns';
import campaigns from 'dashboard/store/modules/campaigns';
import { useAlert, useTrack } from 'dashboard/composables';
import { CAMPAIGNS_EVENTS } from 'dashboard/helper/AnalyticsHelper/events';
import { CAMPAIGN_TYPES } from 'shared/constants/campaign';
import WhatsAppTemplateParser from 'dashboard/components-next/whatsapp/WhatsAppTemplateParser.vue';
import WhatsAppCampaignDialog from '../WhatsAppCampaignDialog.vue';

vi.mock('dashboard/api/campaigns', () => ({
  default: { create: vi.fn() },
}));
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const template = {
  id: 'trip-reminder',
  name: 'trip_reminder',
  namespace: 'dive-trips',
  category: 'UTILITY',
  language: 'en_US',
  components: [{ type: 'BODY', text: 'Meet {{1}} at {{2}}.' }],
};

const expectedPayload = {
  title: 'Dive trip reminder',
  message: 'Meet Kevin at the harbor.',
  inbox_id: 1,
  scheduled_at: new Date('2030-01-01T10:00').toISOString(),
  audience: [{ id: 3, type: 'Label' }],
  template_params: {
    name: 'trip_reminder',
    namespace: 'dive-trips',
    category: 'UTILITY',
    language: 'en_US',
    processed_params: { body: { 1: 'Kevin', 2: 'the harbor' } },
  },
};

const ComboBoxStub = {
  props: ['modelValue', 'options'],
  emits: ['update:modelValue'],
  template: `<select :value="modelValue" @change="$emit('update:modelValue', options.find(option => String(option.value) === $event.target.value).value)">
    <option value="" />
    <option v-for="option in options" :key="option.value" :value="option.value">{{ option.label }}</option>
  </select>`,
};

const AudienceStub = {
  props: ['modelValue', 'options'],
  emits: ['update:modelValue'],
  template: `<select data-test="audience" multiple :value="modelValue" @change="$emit('update:modelValue', Array.from($event.target.selectedOptions, option => Number(option.value)))">
    <option v-for="option in options" :key="option.value" :value="option.value">{{ option.label }}</option>
  </select>`,
};

const ButtonStub = {
  props: ['label', 'isLoading'],
  template: '<button :data-loading="isLoading">{{ label }}</button>',
};

// Use native controls for selectors, but keep the form, Vuelidate, template
// parser, input fields and Vuex creation action real.
const fillDraft = async wrapper => {
  await wrapper.find('input').setValue('Dive trip reminder');
  await wrapper.find('#inbox').setValue('1');
  await wrapper.find('#template').setValue('trip-reminder');
  const parser = wrapper.findComponent(WhatsAppTemplateParser);
  await parser.findAll('input')[0].setValue('Kevin');
  await parser.findAll('input')[1].setValue('the harbor');
  await wrapper.find('[data-test="audience"]').setValue(['3']);
  await wrapper
    .find('input[type="datetime-local"]')
    .setValue('2030-01-01T10:00');
};

const expectDraft = wrapper => {
  expect(wrapper.find('input').element.value).toBe('Dive trip reminder');
  expect(wrapper.find('#inbox').element.value).toBe('1');
  expect(wrapper.find('#template').element.value).toBe('trip-reminder');
  expect(
    wrapper.find('[data-test="audience"]').element.selectedOptions[0].value
  ).toBe('3');
  expect(wrapper.find('input[type="datetime-local"]').element.value).toBe(
    '2030-01-01T10:00'
  );
  const parser = wrapper.findComponent(WhatsAppTemplateParser);
  expect(parser.props('template')).toEqual(template);
  expect(parser.findAll('input').map(input => input.element.value)).toEqual([
    'Kevin',
    'the harbor',
  ]);
  expect(parser.vm.isFormInvalid).toBe(false);
};

describe('WhatsAppCampaignDialog creation lifecycle', () => {
  let wrapper;
  let store;
  let resolveCreate;
  let rejectCreate;

  beforeEach(() => {
    CampaignsAPI.create.mockImplementation(
      () =>
        new Promise((resolve, reject) => {
          resolveCreate = resolve;
          rejectCreate = reject;
        })
    );
    store = createStore({
      modules: {
        campaigns: {
          ...campaigns,
          state: { records: [], uiFlags: { isCreating: false } },
        },
      },
      getters: {
        'labels/getLabels': () => [{ id: 3, title: 'Divers' }],
        'inboxes/getWhatsAppInboxes': () => [{ id: 1, name: 'WhatsApp' }],
        'inboxes/getFilteredWhatsAppTemplates': () => () => [template],
      },
    });
    wrapper = mount(WhatsAppCampaignDialog, {
      global: {
        plugins: [store],
        mocks: { $t: key => key },
        stubs: {
          ComboBox: ComboBoxStub,
          TagMultiSelectComboBox: AudienceStub,
          Button: ButtonStub,
        },
      },
    });
  });

  afterEach(() => wrapper.unmount());

  it('retains the template, parameters and all choices while pending and rejected, then retries unchanged', async () => {
    await fillDraft(wrapper);
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(CampaignsAPI.create).toHaveBeenCalledExactlyOnceWith(
      expectedPayload
    );
    expect(wrapper.emitted('close')).toBeUndefined();
    expectDraft(wrapper);
    expect(store.state.campaigns.uiFlags.isCreating).toBe(true);
    expect(
      wrapper.find('button[type="submit"]').attributes('disabled')
    ).toBeDefined();
    expect(
      wrapper.find('button[type="submit"]').attributes('data-loading')
    ).toBe('true');
    expect(useTrack).not.toHaveBeenCalled();
    expect(useAlert).not.toHaveBeenCalled();

    rejectCreate(new Error('Network unavailable'));
    await flushPromises();

    expect(wrapper.emitted('close')).toBeUndefined();
    expectDraft(wrapper);
    expect(store.state.campaigns.uiFlags.isCreating).toBe(false);
    expect(store.state.campaigns.records).toEqual([]);
    expect(
      wrapper.find('button[type="submit"]').attributes('disabled')
    ).toBeUndefined();
    expect(
      wrapper.find('button[type="submit"]').attributes('data-loading')
    ).toBe('false');
    expect(useAlert).toHaveBeenCalledExactlyOnceWith(
      'CAMPAIGN.WHATSAPP.CREATE.FORM.API.ERROR_MESSAGE'
    );
    expect(useTrack).not.toHaveBeenCalled();

    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.create).toHaveBeenCalledTimes(2);
    expect(CampaignsAPI.create).toHaveBeenNthCalledWith(2, expectedPayload);
    expect(wrapper.emitted('close')).toBeUndefined();
    resolveCreate({ data: { id: 42, ...expectedPayload } });
    await flushPromises();

    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(store.state.campaigns.records).toEqual([
      { id: 42, ...expectedPayload },
    ]);
    expect(store.state.campaigns.uiFlags.isCreating).toBe(false);
    expect(useTrack).toHaveBeenCalledExactlyOnceWith(
      CAMPAIGNS_EVENTS.CREATE_CAMPAIGN,
      { type: CAMPAIGN_TYPES.ONE_OFF }
    );
    expect(useAlert.mock.calls).toEqual([
      ['CAMPAIGN.WHATSAPP.CREATE.FORM.API.ERROR_MESSAGE'],
      ['CAMPAIGN.WHATSAPP.CREATE.FORM.API.SUCCESS_MESSAGE'],
    ]);
  });

  it('closes exactly once and preserves success analytics and alert on first-attempt success', async () => {
    await fillDraft(wrapper);
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(wrapper.emitted('close')).toBeUndefined();
    resolveCreate({ data: { id: 42, ...expectedPayload } });
    await flushPromises();
    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(useTrack).toHaveBeenCalledExactlyOnceWith(
      CAMPAIGNS_EVENTS.CREATE_CAMPAIGN,
      { type: CAMPAIGN_TYPES.ONE_OFF }
    );
    expect(useAlert).toHaveBeenCalledExactlyOnceWith(
      'CAMPAIGN.WHATSAPP.CREATE.FORM.API.SUCCESS_MESSAGE'
    );
  });

  it('rejects empty form fields without submitting or closing', async () => {
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.create).not.toHaveBeenCalled();
    expect(wrapper.emitted('close')).toBeUndefined();
    expect(wrapper.text()).toContain(
      'CAMPAIGN.WHATSAPP.CREATE.FORM.TITLE.ERROR'
    );
  });

  it('rejects missing template parameters even when the other fields are valid', async () => {
    await fillDraft(wrapper);
    const parser = wrapper.findComponent(WhatsAppTemplateParser);
    await parser.find('input').setValue('');
    expect(parser.vm.isFormInvalid).toBe(true);
    expect(
      wrapper.find('button[type="submit"]').attributes('disabled')
    ).toBeDefined();
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.create).not.toHaveBeenCalled();
    expect(wrapper.emitted('close')).toBeUndefined();
  });

  it('retains explicit cancellation without submitting', async () => {
    await fillDraft(wrapper);
    await wrapper.find('button[type="button"]').trigger('click');
    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(CampaignsAPI.create).not.toHaveBeenCalled();
    expect(useTrack).not.toHaveBeenCalled();
    expect(useAlert).not.toHaveBeenCalled();
  });
});
