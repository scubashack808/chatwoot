import { shallowMount } from '@vue/test-utils';
import Profile from './Index.vue';
import UserBasicDetails from './UserBasicDetails.vue';
import { actions } from 'dashboard/store/modules/auth';
import types from 'dashboard/store/mutation-types';
import authAPI from 'dashboard/api/auth';

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useUISettings');
vi.mock('dashboard/composables/useFontSize');
vi.mock('shared/composables/useBranding');
vi.mock('./UserProfilePicture.vue', () => ({ default: {} }));
vi.mock('./MessageSignature.vue', () => ({ default: {} }));
vi.mock('./FontSize.vue', () => ({ default: {} }));
vi.mock('./UserLanguageSelect.vue', () => ({ default: {} }));
vi.mock('./ChangePassword.vue', () => ({ default: {} }));
vi.mock('./NotificationPreferences.vue', () => ({ default: {} }));
vi.mock('./AudioNotifications.vue', () => ({ default: {} }));
vi.mock('./AccessToken.vue', () => ({ default: {} }));
vi.mock('./MfaSettingsCard.vue', () => ({ default: {} }));
vi.mock('./ActiveSessions.vue', () => ({ default: {} }));
vi.mock('dashboard/components/policy.vue', () => ({ default: {} }));
vi.mock('../components/BaseSettingsHeader.vue', () => ({ default: {} }));
vi.mock('../account/components/SectionLayout.vue', () => ({ default: {} }));

const put = vi.fn();
const commit = vi.fn();
let context;

beforeEach(() => {
  vi.stubGlobal('axios', { put });
  put.mockResolvedValue({ data: { id: 7 } });
  context = {
    name: 'Synthetic User',
    email: 'synthetic@example.test',
    displayName: 'Dive Guide',
    avatarFile: '',
    currentUser: { email: 'synthetic@example.test' },
    $t: key => key,
    $store: {
      dispatch: (action, payload) => {
        expect(action).toBe('updateProfile');
        return actions.updateProfile({ commit }, payload);
      },
    },
  };
  context.dispatchUpdate = Profile.methods.dispatchUpdate.bind(context);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('profile display name updates', () => {
  it('sends an intentional clear from the basic-details form through the action to HTTP', async () => {
    const wrapper = shallowMount(UserBasicDetails, {
      props: {
        name: context.name,
        email: context.email,
        displayName: context.displayName,
        emailEnabled: true,
      },
      global: { mocks: { $t: key => key }, stubs: { 'woot-input': true } },
    });
    await wrapper.setData({ userDisplayName: '' });
    await wrapper.vm.updateUser();
    const [payload] = wrapper.emitted('updateUser')[0];
    wrapper.unmount();

    expect(payload.displayName).toBe('');
    await Profile.methods.updateProfile.call(context, payload);

    expect(put).toHaveBeenCalledOnce();
    const [url, form] = put.mock.calls[0];
    expect(url).toBe('/api/v1/profile');
    expect(form.get('profile[display_name]')).toBe('');
    expect(form.get('profile[name]')).toBe(context.name);
    expect(form.get('profile[email]')).toBe(context.email);
    expect(context.displayName).toBe('');
    expect(commit).toHaveBeenCalledWith(types.SET_CURRENT_USER, { id: 7 });
  });

  it('sends only the signature when saving a signature', async () => {
    await Profile.methods.updateSignature.call(context, 'Thanks, Synthetic');

    expect(put).toHaveBeenCalledOnce();
    expect([...put.mock.calls[0][1].entries()]).toEqual([
      ['profile[message_signature]', 'Thanks, Synthetic'],
    ]);
    expect(context.displayName).toBe('Dive Guide');
    expect(commit).toHaveBeenCalledWith(types.SET_CURRENT_USER, { id: 7 });
  });

  it('preserves a nonempty replacement', async () => {
    await Profile.methods.updateProfile.call(context, {
      name: context.name,
      email: context.email,
      displayName: 'Captain',
    });

    expect(put.mock.calls[0][1].get('profile[display_name]')).toBe('Captain');
    expect(context.displayName).toBe('Captain');
  });

  it('does not manufacture a display-name change when omitted from basic details', async () => {
    await Profile.methods.updateProfile.call(context, {
      name: context.name,
      email: context.email,
    });

    expect(put.mock.calls[0][1].has('profile[display_name]')).toBe(false);
    expect(context.displayName).toBe('Dive Guide');
  });

  it('supports a direct API clear', async () => {
    await authAPI.profileUpdate({ displayName: '' });

    expect(put.mock.calls[0][1].get('profile[display_name]')).toBe('');
  });

  it.each([{}, { displayName: undefined }])(
    'omits absent or undefined display names from API payloads: %j',
    async attributes => {
      await authAPI.profileUpdate({
        message_signature: 'Thanks, Synthetic',
        ...attributes,
      });

      const form = put.mock.calls[0][1];
      expect(form.has('profile[display_name]')).toBe(false);
      expect(form.get('profile[message_signature]')).toBe('Thanks, Synthetic');
    }
  );
});
