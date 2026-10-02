import { flushPromises, mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import UserNotificationSettings from 'dashboard/api/userNotificationSettings';
import { useAlert } from 'dashboard/composables';
import notificationModule from 'dashboard/store/modules/userNotificationSettings';
import NotificationPreferences from '../NotificationPreferences.vue';

vi.mock('dashboard/api/userNotificationSettings', () => ({
  default: { get: vi.fn(), update: vi.fn() },
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/helper/pushHelper.js', () => ({
  hasPushPermissions: vi.fn(() => false),
  requestPushPermissions: vi.fn(),
  verifyServiceWorkerExistence: vi.fn(),
}));

describe('NotificationPreferences persistence feedback', () => {
  let wrapper;
  let store;
  let persisted;
  let resolvePatch;
  let rejectPatch;
  let resolveGet;

  beforeEach(() => {
    resolvePatch = undefined;
    persisted = {
      selected_email_flags: ['email_conversation_creation'],
      selected_push_flags: ['push_conversation_creation'],
    };
    store = createStore({
      getters: {
        getCurrentAccountId: () => 1,
        'accounts/isFeatureEnabledonAccount': () => () => false,
      },
      modules: {
        userNotificationSettings: {
          ...notificationModule,
          state: {
            record: {},
            uiFlags: { isFetching: false, isUpdating: false },
          },
        },
      },
    });
    UserNotificationSettings.get.mockImplementation(
      () =>
        new Promise(resolve => {
          resolveGet = resolve;
        })
    );
    UserNotificationSettings.update.mockImplementation(
      () =>
        new Promise((resolve, reject) => {
          resolvePatch = resolve;
          rejectPatch = reject;
        })
    );
    wrapper = mount(NotificationPreferences, {
      global: {
        plugins: [store],
        mocks: { $t: key => key },
        stubs: {
          TableHeaderCell: true,
          ToggleSwitch: true,
          'fluent-icon': true,
        },
      },
    });
  });

  afterEach(async () => {
    resolveGet({ data: persisted });
    resolvePatch?.({ data: persisted });
    await flushPromises();
    wrapper.unmount();
  });

  describe.each([
    ['email', 0, 'desktop'],
    ['email', 1, 'mobile'],
    ['push', 0, 'desktop'],
    ['push', 1, 'mobile'],
  ])('%s checkbox at index %s (%s layout)', (type, index) => {
    it('waits for persistence before reporting success', async () => {
      resolveGet({ data: persisted });
      await flushPromises();
      const inputs = wrapper.findAll(
        `input[value="${type}_conversation_creation"]`
      );
      expect(inputs).toHaveLength(2);
      expect(inputs.every(input => input.element.checked)).toBe(true);
      await inputs[index].setValue(false);
      const saved = { ...persisted, [`selected_${type}_flags`]: [] };
      expect(UserNotificationSettings.update).toHaveBeenCalledExactlyOnceWith({
        notification_settings: saved,
      });
      expect(store.state.userNotificationSettings.record).toEqual(persisted);
      expect(store.state.userNotificationSettings.uiFlags.isUpdating).toBe(
        true
      );
      expect(useAlert).not.toHaveBeenCalled();

      resolvePatch({ data: saved });
      await flushPromises();
      expect(store.state.userNotificationSettings.record).toEqual(saved);
      expect(store.state.userNotificationSettings.uiFlags.isUpdating).toBe(
        false
      );
      expect(inputs.every(input => !input.element.checked)).toBe(true);
      expect(useAlert).toHaveBeenCalledExactlyOnceWith(
        'PROFILE_SETTINGS.FORM.API.UPDATE_SUCCESS'
      );
    });

    it('restores both selections after rejection and allows a successful retry', async () => {
      resolveGet({ data: persisted });
      await flushPromises();
      const inputs = wrapper.findAll(
        `input[value="${type}_conversation_creation"]`
      );
      await inputs[index].setValue(false);
      rejectPatch(new Error('Synthetic rejected PATCH'));
      await flushPromises();

      expect(store.state.userNotificationSettings.record).toEqual(persisted);
      expect(store.state.userNotificationSettings.uiFlags.isUpdating).toBe(
        false
      );
      expect(wrapper.vm.selectedEmailFlags).toEqual(
        persisted.selected_email_flags
      );
      expect(wrapper.vm.selectedPushFlags).toEqual(
        persisted.selected_push_flags
      );
      expect(wrapper.vm.selectedEmailFlags).not.toBe(wrapper.vm.emailFlags);
      expect(wrapper.vm.selectedPushFlags).not.toBe(wrapper.vm.pushFlags);
      expect(
        wrapper
          .findAll('input[value$="_conversation_creation"]')
          .every(input => input.element.checked)
      ).toBe(true);
      expect(useAlert).toHaveBeenCalledExactlyOnceWith(
        'PROFILE_SETTINGS.FORM.API.UPDATE_ERROR'
      );

      await inputs[index].setValue(false);
      const saved = { ...persisted, [`selected_${type}_flags`]: [] };
      expect(UserNotificationSettings.update).toHaveBeenLastCalledWith({
        notification_settings: saved,
      });
      expect(UserNotificationSettings.update).toHaveBeenCalledTimes(2);
      expect(useAlert).toHaveBeenCalledTimes(1);
      resolvePatch({ data: saved });
      await flushPromises();
      expect(store.state.userNotificationSettings.record).toEqual(saved);
      expect(store.state.userNotificationSettings.uiFlags.isUpdating).toBe(
        false
      );
      expect(inputs.every(input => !input.element.checked)).toBe(true);
      expect(useAlert.mock.calls).toEqual([
        ['PROFILE_SETTINGS.FORM.API.UPDATE_ERROR'],
        ['PROFILE_SETTINGS.FORM.API.UPDATE_SUCCESS'],
      ]);
    });
  });

  it('restores empty arrays if the initial preferences have not loaded', async () => {
    expect(store.state.userNotificationSettings.uiFlags.isFetching).toBe(true);
    await wrapper
      .find('input[value="email_conversation_creation"]')
      .setValue(true);
    rejectPatch(new Error('Synthetic rejected PATCH'));
    await flushPromises();
    expect(wrapper.vm.selectedEmailFlags).toEqual([]);
    expect(wrapper.vm.selectedPushFlags).toEqual([]);
    expect(store.state.userNotificationSettings.record).toEqual({});
    expect(store.state.userNotificationSettings.uiFlags.isUpdating).toBe(false);
    expect(
      wrapper.findAll('input').every(input => !input.element.checked)
    ).toBe(true);
    expect(useAlert).toHaveBeenCalledExactlyOnceWith(
      'PROFILE_SETTINGS.FORM.API.UPDATE_ERROR'
    );
  });
});
