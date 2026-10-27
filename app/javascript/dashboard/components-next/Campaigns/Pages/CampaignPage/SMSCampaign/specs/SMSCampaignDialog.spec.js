import { mount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import campaigns from 'dashboard/store/modules/campaigns';
import CampaignsAPI from 'dashboard/api/campaigns';
import { useAlert, useTrack } from 'dashboard/composables';
import { CAMPAIGNS_EVENTS } from 'dashboard/helper/AnalyticsHelper/events';
import SMSCampaignDialog from '../SMSCampaignDialog.vue';

vi.mock('dashboard/api/campaigns', () => ({ default: { create: vi.fn() } }));
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const draft = {
  title: 'Dive trip reminder',
  message: 'Meet at the harbor entrance at 7am.',
  inbox_id: 1,
  scheduled_at: new Date('2030-01-01T10:00').toISOString(),
  audience: [{ id: 3, type: 'Label' }],
};

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
      'inboxes/getSMSInboxes': () => [{ id: 1, name: 'SMS' }],
    },
  });
  wrapper = mount(SMSCampaignDialog, {
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
      },
    },
  });
});

afterEach(() => wrapper.unmount());

const fillDraft = async () => {
  await wrapper.find('input').setValue(draft.title);
  await wrapper.find('textarea').setValue(draft.message);
  await wrapper.find('#inbox').setValue('1');
  await wrapper.find('[data-test="audience"]').setValue(['3']);
  await wrapper
    .find('input[type="datetime-local"]')
    .setValue('2030-01-01T10:00');
};

const expectDraft = () => {
  expect(wrapper.find('input').element.value).toBe(draft.title);
  expect(wrapper.find('textarea').element.value).toBe(draft.message);
  expect(wrapper.find('#inbox').element.value).toBe('1');
  expect(
    wrapper.find('[data-test="audience"]').element.selectedOptions[0].value
  ).toBe('3');
  expect(wrapper.find('input[type="datetime-local"]').element.value).toBe(
    '2030-01-01T10:00'
  );
};

describe('SMS campaign creation lifecycle', () => {
  it('retains every field while pending and rejected, then retries unchanged and closes once', async () => {
    await fillDraft();
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.create).toHaveBeenCalledExactlyOnceWith(draft);
    expect(wrapper.emitted('close')).toBeUndefined();
    expectDraft();
    expect(store.state.campaigns.uiFlags.isCreating).toBe(true);
    expect(
      wrapper.find('button[type="submit"]').attributes('disabled')
    ).toBeDefined();
    expect(useAlert).not.toHaveBeenCalled();
    expect(useTrack).not.toHaveBeenCalled();

    rejectCreate(new Error('Synthetic failure'));
    await flushPromises();
    expect(wrapper.emitted('close')).toBeUndefined();
    expectDraft();
    expect(store.state.campaigns.uiFlags.isCreating).toBe(false);
    expect(
      wrapper.find('button[type="submit"]').attributes('disabled')
    ).toBeUndefined();
    expect(store.state.campaigns.records).toEqual([]);
    expect(useAlert).toHaveBeenCalledWith(
      'CAMPAIGN.SMS.CREATE.FORM.API.ERROR_MESSAGE'
    );

    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.create).toHaveBeenNthCalledWith(2, draft);
    resolveCreate({ data: { ...draft, id: 99 } });
    await flushPromises();
    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(useAlert).toHaveBeenCalledWith(
      'CAMPAIGN.SMS.CREATE.FORM.API.SUCCESS_MESSAGE'
    );
    expect(useTrack).toHaveBeenCalledExactlyOnceWith(
      CAMPAIGNS_EVENTS.CREATE_CAMPAIGN,
      { type: 'one_off' }
    );
    expect(store.state.campaigns.records).toHaveLength(1);
  });

  it('closes exactly once after a successful first submission', async () => {
    await fillDraft();
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(wrapper.emitted('close')).toBeUndefined();
    resolveCreate({ data: { ...draft, id: 99 } });
    await flushPromises();
    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(useAlert).toHaveBeenCalledWith(
      'CAMPAIGN.SMS.CREATE.FORM.API.SUCCESS_MESSAGE'
    );
  });

  it('does not request or close for invalid input', async () => {
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.create).not.toHaveBeenCalled();
    expect(wrapper.emitted('close')).toBeUndefined();
  });

  it('preserves explicit cancellation', async () => {
    await fillDraft();
    await wrapper.find('button[type="button"]').trigger('click');
    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(CampaignsAPI.create).not.toHaveBeenCalled();
  });
});
