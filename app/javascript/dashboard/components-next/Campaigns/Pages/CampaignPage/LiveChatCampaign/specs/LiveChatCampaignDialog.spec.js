import { shallowMount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import LiveChatCampaignDialog from '../LiveChatCampaignDialog.vue';
import EditLiveChatCampaignDialog from '../EditLiveChatCampaignDialog.vue';
import LiveChatCampaignForm from '../LiveChatCampaignForm.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import campaigns from 'dashboard/store/modules/campaigns';
import CampaignsAPI from 'dashboard/api/campaigns';
import { useAlert, useTrack } from 'dashboard/composables';
import { CAMPAIGNS_EVENTS } from 'dashboard/helper/AnalyticsHelper/events';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));
vi.mock('dashboard/api/campaigns', () => ({
  default: { create: vi.fn(), update: vi.fn() },
}));
vi.mock('dashboard/helper/AnalyticsHelper', () => ({
  default: { track: vi.fn() },
}));

const draft = {
  title: 'Dive trip reminder',
  message: 'Meet at the harbor entrance at 7am.',
  inbox_id: 1,
  sender_id: 7,
  enabled: false,
  trigger_only_during_business_hours: true,
  trigger_rules: { url: 'https://example.com/diving/*', time_on_page: 25 },
};
const record = {
  id: 99,
  title: draft.title,
  message: draft.message,
  inbox: { id: 1, channel_type: 'Channel::WebWidget' },
  sender: { id: 7 },
  enabled: draft.enabled,
  trigger_only_during_business_hours: true,
  trigger_rules: draft.trigger_rules,
  campaign_type: 'ongoing',
};

let wrapper;
let store;
let resolveRequest;
let rejectRequest;
let getInboxMembers;
const closeDialog = vi.fn();

beforeEach(() => {
  getInboxMembers = vi.fn().mockResolvedValue({
    data: { payload: [{ id: 7, name: 'Captain' }] },
  });
  store = createStore({
    getters: {
      'inboxes/getWebsiteInboxes': () => [{ id: 1, name: 'Website' }],
    },
    actions: { 'inboxMembers/get': getInboxMembers },
    modules: {
      campaigns: {
        ...campaigns,
        state: { records: [], uiFlags: { isCreating: false } },
      },
    },
  });
  CampaignsAPI.create.mockImplementation(
    () =>
      new Promise((resolve, reject) => {
        resolveRequest = resolve;
        rejectRequest = reject;
      })
  );
  CampaignsAPI.update.mockImplementation(
    () =>
      new Promise((resolve, reject) => {
        resolveRequest = resolve;
        rejectRequest = reject;
      })
  );
  wrapper = shallowMount(LiveChatCampaignDialog, {
    global: {
      plugins: [store],
      mocks: { $t: key => key },
      stubs: { LiveChatCampaignForm: false },
    },
  });
});

afterEach(() => wrapper.unmount());

// Model events keep the actual form validation and payload construction in use.
const fillDraft = async () => {
  const form = wrapper.findComponent(LiveChatCampaignForm);
  const inputs = form.findAllComponents(Input);
  inputs[0].vm.$emit('update:modelValue', draft.title);
  form.findComponent(Editor).vm.$emit('update:modelValue', draft.message);
  form.findAllComponents(ComboBox)[0].vm.$emit('update:modelValue', 1);
  await flushPromises();
  form.findAllComponents(ComboBox)[1].vm.$emit('update:modelValue', 7);
  inputs[1].vm.$emit('update:modelValue', draft.trigger_rules.url);
  inputs[2].vm.$emit('update:modelValue', draft.trigger_rules.time_on_page);
  await form.findAll('input[type="checkbox"]')[0].setValue(false);
  await form.findAll('input[type="checkbox"]')[1].setValue(true);
  await flushPromises();
};

const expectDraft = () => {
  const form = wrapper.findComponent(LiveChatCampaignForm);
  expect(
    form.findAllComponents(Input).map(input => input.props('modelValue'))
  ).toEqual([
    draft.title,
    draft.trigger_rules.url,
    draft.trigger_rules.time_on_page,
  ]);
  expect(form.findComponent(Editor).props('modelValue')).toBe(draft.message);
  expect(
    form.findAllComponents(ComboBox).map(input => input.props('modelValue'))
  ).toEqual([1, 7]);
  expect(
    form.findAll('input[type="checkbox"]').map(input => input.element.checked)
  ).toEqual([false, true]);
};

describe('LiveChat campaign creation lifecycle', () => {
  it('retains every field pending and rejected, then retries the same payload and closes once on success', async () => {
    await fillDraft();
    expect(getInboxMembers).toHaveBeenCalledWith(expect.anything(), {
      inboxId: 1,
    });
    expect(
      wrapper
        .findComponent(LiveChatCampaignForm)
        .findAllComponents(ComboBox)[1]
        .props('options')
    ).toContainEqual({ value: 7, label: 'Captain' });
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.create).toHaveBeenCalledExactlyOnceWith(draft);
    expect(store.state.campaigns.uiFlags.isCreating).toBe(true);
    expect(wrapper.emitted('close')).toBeUndefined();
    expectDraft();
    expect(useAlert).not.toHaveBeenCalled();
    expect(useTrack).not.toHaveBeenCalled();

    rejectRequest(new Error('Synthetic failure'));
    await flushPromises();
    expect(wrapper.emitted('close')).toBeUndefined();
    expectDraft();
    expect(store.state.campaigns.uiFlags.isCreating).toBe(false);
    expect(useAlert).toHaveBeenCalledWith(
      'CAMPAIGN.LIVE_CHAT.CREATE.FORM.API.ERROR_MESSAGE'
    );
    expect(store.state.campaigns.records).toEqual([]);

    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.create).toHaveBeenNthCalledWith(2, draft);
    expect(wrapper.emitted('close')).toBeUndefined();
    resolveRequest({ data: record });
    await flushPromises();
    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(useAlert).toHaveBeenCalledWith(
      'CAMPAIGN.LIVE_CHAT.CREATE.FORM.API.SUCCESS_MESSAGE'
    );
    expect(useTrack).toHaveBeenCalledExactlyOnceWith(
      CAMPAIGNS_EVENTS.CREATE_CAMPAIGN,
      { type: 'ongoing' }
    );
    expect(store.state.campaigns.records).toEqual([record]);
  });

  it('does not submit an empty form', async () => {
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.create).not.toHaveBeenCalled();
    expect(wrapper.emitted('close')).toBeUndefined();
  });

  it('does not submit an invalid URL even when other fields are valid', async () => {
    await fillDraft();
    wrapper
      .findComponent(LiveChatCampaignForm)
      .findAllComponents(Input)[1]
      .vm.$emit('update:modelValue', 'not a URL');
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.create).not.toHaveBeenCalled();
    expect(wrapper.emitted('close')).toBeUndefined();
  });

  it('still closes on explicit cancellation without creating', async () => {
    await fillDraft();
    wrapper
      .findComponent(LiveChatCampaignForm)
      .findAllComponents(Button)[0]
      .vm.$emit('click');
    expect(wrapper.emitted('close')).toHaveLength(1);
    expect(CampaignsAPI.create).not.toHaveBeenCalled();
  });
});

describe('LiveChat campaign editing lifecycle', () => {
  it('preserves the edit draft on rejection and closes only after a successful update', async () => {
    wrapper.unmount();
    store.state.campaigns.records = [record];
    wrapper = shallowMount(EditLiveChatCampaignDialog, {
      props: { selectedCampaign: record },
      global: {
        plugins: [store],
        mocks: { $t: key => key },
        stubs: {
          LiveChatCampaignForm: false,
          Dialog: {
            template: '<div><slot /></div>',
            methods: { close: closeDialog },
          },
        },
      },
    });
    await flushPromises();
    expectDraft();
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.update).toHaveBeenCalledExactlyOnceWith(99, draft);
    expect(closeDialog).not.toHaveBeenCalled();
    expectDraft();
    rejectRequest(new Error('Synthetic update failure'));
    await flushPromises();
    expectDraft();
    expect(closeDialog).not.toHaveBeenCalled();
    expect(useAlert).toHaveBeenCalledWith(
      'CAMPAIGN.LIVE_CHAT.EDIT.FORM.API.ERROR_MESSAGE'
    );
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(CampaignsAPI.update).toHaveBeenNthCalledWith(2, 99, draft);
    resolveRequest({ data: record });
    await flushPromises();
    expect(closeDialog).toHaveBeenCalledOnce();
    expect(useAlert).toHaveBeenCalledWith(
      'CAMPAIGN.LIVE_CHAT.EDIT.FORM.API.SUCCESS_MESSAGE'
    );
  });
});
