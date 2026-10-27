import { mount, flushPromises } from '@vue/test-utils';
import MfaSettings from './MfaSettings.vue';
import MfaSetupWizard from './MfaSetupWizard.vue';
import MfaStatusCard from './MfaStatusCard.vue';
import mfaAPI from 'dashboard/api/mfa';
import { useAlert } from 'dashboard/composables';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('vue-router', async importOriginal => ({
  ...(await importOriginal()),
  useRouter: () => ({ push: vi.fn() }),
  useRoute: () => ({ params: { accountId: 1 } }),
}));
vi.mock('qrcode', () => ({
  default: {
    toDataURL: vi.fn().mockResolvedValue('data:image/png;base64,test'),
  },
}));

const backupCodes = Array.from({ length: 10 }, (_, i) => `BACKUP0${i}`);

describe('MFA setup verification', () => {
  let wrapper;
  let resolveVerify;
  let rejectVerify;
  let previousConfig;
  let vueErrors;

  const button = label =>
    wrapper.findAll('button').find(node => node.text() === label);

  beforeEach(async () => {
    previousConfig = window.chatwootConfig;
    window.chatwootConfig = { isMfaEnabled: true };
    vi.spyOn(mfaAPI, 'get').mockResolvedValue({
      data: { enabled: false, backup_codes_generated: false },
    });
    vi.spyOn(mfaAPI, 'enable').mockResolvedValue({
      data: {
        provisioning_uri: 'otpauth://totp/Test?secret=TEST',
        secret: 'TEST',
      },
    });
    vi.spyOn(mfaAPI, 'verify').mockImplementation(
      () =>
        new Promise((resolve, reject) => {
          resolveVerify = resolve;
          rejectVerify = reject;
        })
    );
    vi.spyOn(emitter, 'emit');
    vueErrors = [];
    wrapper = mount(MfaSettings, {
      global: {
        stubs: {
          BaseSettingsHeader: true,
          MfaManagementActions: true,
          Icon: true,
        },
        config: { errorHandler: error => vueErrors.push(error) },
      },
    });
    await flushPromises();
    await button('MFA_SETTINGS.ENABLE_BUTTON').trigger('click');
    await flushPromises();
  });

  afterEach(() => {
    wrapper.unmount();
    window.chatwootConfig = previousConfig;
    vi.restoreAllMocks();
  });

  it('keeps the entered code visible while verification is pending', async () => {
    await wrapper.get('input[maxlength="6"]').setValue('000000');
    await button('MFA_SETTINGS.SETUP.VERIFY_BUTTON').trigger('click');
    expect(mfaAPI.verify).toHaveBeenCalledWith('000000');
    expect(wrapper.find('input[maxlength="6"]').exists()).toBe(true);
    expect(wrapper.get('input[maxlength="6"]').element.value).toBe('000000');
    expect(wrapper.find('input[type="checkbox"]').exists()).toBe(false);
  });

  it('preserves rejected input and shows the error for correction', async () => {
    await wrapper.get('input[maxlength="6"]').setValue('000000');
    await button('MFA_SETTINGS.SETUP.VERIFY_BUTTON').trigger('click');
    rejectVerify({
      response: { data: { error: 'Invalid verification code' } },
    });
    await flushPromises();
    expect(wrapper.find('input[maxlength="6"]').exists()).toBe(true);
    expect(wrapper.get('input[maxlength="6"]').element.value).toBe('000000');
    expect(wrapper.text()).toContain('Invalid verification code');
    expect(wrapper.find('input[type="checkbox"]').exists()).toBe(false);
    expect(vueErrors).toEqual([]);
  });

  it('cannot complete rejected verification as enabled', async () => {
    await wrapper.get('input[maxlength="6"]').setValue('000000');
    await button('MFA_SETTINGS.SETUP.VERIFY_BUTTON').trigger('click');
    rejectVerify(new Error('Rejected'));
    await flushPromises();
    wrapper.getComponent(MfaSetupWizard).vm.$emit('complete');
    await flushPromises();
    expect(wrapper.getComponent(MfaStatusCard).props('mfaEnabled')).toBe(false);
    expect(useAlert).not.toHaveBeenCalled();
    expect(emitter.emit).not.toHaveBeenCalledWith(BUS_EVENTS.MFA_STATE_CHANGED);
  });

  it('allows a corrected code after a fallback error', async () => {
    await wrapper.get('input[maxlength="6"]').setValue('000000');
    await button('MFA_SETTINGS.SETUP.VERIFY_BUTTON').trigger('click');
    rejectVerify(new Error('Network failure'));
    await flushPromises();
    expect(wrapper.text()).toContain('MFA_SETTINGS.SETUP.INVALID_CODE');
    expect(button('MFA_SETTINGS.SETUP.VERIFY_BUTTON').element.disabled).toBe(
      false
    );
    await wrapper.get('input[maxlength="6"]').setValue('123456');
    await wrapper.get('input[maxlength="6"]').trigger('keyup.enter');
    expect(wrapper.text()).not.toContain('MFA_SETTINGS.SETUP.INVALID_CODE');
    expect(mfaAPI.verify).toHaveBeenNthCalledWith(2, '123456');
    resolveVerify({ data: { backup_codes: backupCodes } });
    await flushPromises();
    backupCodes.forEach(code => expect(wrapper.text()).toContain(code));
    await wrapper.get('input[type="checkbox"]').setValue(true);
    await button('MFA_SETTINGS.BACKUP.COMPLETE_SETUP').trigger('click');
    expect(wrapper.getComponent(MfaStatusCard).props('mfaEnabled')).toBe(true);
    expect(vueErrors).toEqual([]);
  });

  it('serializes pending clicks, Enter and emitted requests and disables cancel', async () => {
    await wrapper.get('input[maxlength="6"]').setValue('123456');
    await button('MFA_SETTINGS.SETUP.VERIFY_BUTTON').trigger('click');
    expect(button('MFA_SETTINGS.SETUP.VERIFY_BUTTON').element.disabled).toBe(
      true
    );
    expect(button('MFA_SETTINGS.SETUP.CANCEL').element.disabled).toBe(true);
    await button('MFA_SETTINGS.SETUP.VERIFY_BUTTON').trigger('click');
    await wrapper.get('input[maxlength="6"]').trigger('keyup.enter');
    wrapper.getComponent(MfaSetupWizard).vm.$emit('verify', '123456');
    await button('MFA_SETTINGS.SETUP.CANCEL').trigger('click');
    expect(mfaAPI.verify).toHaveBeenCalledTimes(1);
    expect(wrapper.getComponent(MfaSetupWizard).props('showSetup')).toBe(true);
    resolveVerify({ data: { backup_codes: backupCodes } });
    await flushPromises();
  });

  it('does not submit a short code through Enter', async () => {
    await wrapper.get('input[maxlength="6"]').setValue('123');
    await wrapper.get('input[maxlength="6"]').trigger('keyup.enter');
    expect(mfaAPI.verify).not.toHaveBeenCalled();
  });

  it('cannot complete before verification succeeds', async () => {
    const wizard = wrapper.getComponent(MfaSetupWizard);
    wizard.vm.$emit('complete');
    await wrapper.get('input[maxlength="6"]').setValue('123456');
    await button('MFA_SETTINGS.SETUP.VERIFY_BUTTON').trigger('click');
    wizard.vm.$emit('complete');
    await flushPromises();
    expect(wrapper.getComponent(MfaStatusCard).props('mfaEnabled')).toBe(false);
    expect(useAlert).not.toHaveBeenCalled();
    expect(emitter.emit).not.toHaveBeenCalled();
    rejectVerify(new Error('Rejected'));
    await flushPromises();
  });

  it('resets rejected input and error when cancelled and reopened', async () => {
    await wrapper.get('input[maxlength="6"]').setValue('000000');
    await button('MFA_SETTINGS.SETUP.VERIFY_BUTTON').trigger('click');
    rejectVerify({
      response: { data: { error: 'Invalid verification code' } },
    });
    await flushPromises();
    await button('MFA_SETTINGS.SETUP.CANCEL').trigger('click');
    await button('MFA_SETTINGS.ENABLE_BUTTON').trigger('click');
    await flushPromises();
    expect(wrapper.get('input[maxlength="6"]').element.value).toBe('');
    expect(wrapper.text()).not.toContain('Invalid verification code');
    expect(wrapper.getComponent(MfaSetupWizard).props('backupCodes')).toEqual(
      []
    );
    await wrapper.get('input[maxlength="6"]').setValue('123456');
    await button('MFA_SETTINGS.SETUP.VERIFY_BUTTON').trigger('click');
    resolveVerify({ data: { backup_codes: backupCodes } });
    await flushPromises();
    expect(wrapper.get('input[type="checkbox"]').element.checked).toBe(false);
  });

  it('displays all returned backup codes and requires acknowledgment', async () => {
    await wrapper.get('input[maxlength="6"]').setValue('123456');
    await button('MFA_SETTINGS.SETUP.VERIFY_BUTTON').trigger('click');
    resolveVerify({ data: { backup_codes: backupCodes } });
    await flushPromises();
    backupCodes.forEach(code => expect(wrapper.text()).toContain(code));
    expect(button('MFA_SETTINGS.BACKUP.COMPLETE_SETUP').element.disabled).toBe(
      true
    );
    await wrapper.get('input[type="checkbox"]').setValue(true);
    await button('MFA_SETTINGS.BACKUP.COMPLETE_SETUP').trigger('click');
    await flushPromises();
    expect(wrapper.getComponent(MfaStatusCard).props('mfaEnabled')).toBe(true);
    expect(useAlert).toHaveBeenCalledExactlyOnceWith(
      'MFA_SETTINGS.SETUP.SUCCESS'
    );
    expect(emitter.emit).toHaveBeenCalledExactlyOnceWith(
      BUS_EVENTS.MFA_STATE_CHANGED
    );
    expect(vueErrors).toEqual([]);
  });
});
