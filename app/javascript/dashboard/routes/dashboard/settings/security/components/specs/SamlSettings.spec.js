import { flushPromises, shallowMount } from '@vue/test-utils';
import { useAlert } from 'dashboard/composables';
import samlSettingsAPI from 'dashboard/api/samlSettings';
import Switch from 'next/switch/Switch.vue';
import TextInput from 'next/input/Input.vue';
import TextArea from 'next/textarea/TextArea.vue';
import SamlSettings from '../SamlSettings.vue';

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ isCloudFeatureEnabled: () => true }),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/api/samlSettings', () => ({
  default: { get: vi.fn(), delete: vi.fn() },
}));

const settings = {
  id: 7,
  sso_url: 'https://idp.example.test/sso',
  certificate: 'synthetic-certificate',
  idp_entity_id: 'urn:synthetic:idp',
  sp_entity_id: 'urn:synthetic:sp',
  fingerprint: 'synthetic-fingerprint',
};

describe('SamlSettings', () => {
  let errors;

  const mountComponent = async () => {
    const wrapper = shallowMount(SamlSettings, {
      global: {
        config: { errorHandler: error => errors.push(error) },
        stubs: {
          SectionLayout: {
            props: ['hideContent'],
            template:
              '<div><slot name="headerActions" /><div v-if="!hideContent"><slot /></div></div>',
          },
          WithLabel: { template: '<div><slot /></div>' },
        },
      },
    });
    await flushPromises();
    return wrapper;
  };

  const toggle = async (wrapper, enabled) => {
    const input = wrapper.findComponent(Switch);
    input.vm.$emit('update:modelValue', enabled);
    input.vm.$emit('change', enabled);
    await flushPromises();
  };

  const formValues = wrapper => {
    const [ssoUrl, idpEntityId] = wrapper
      .findAllComponents(TextInput)
      .map(input => input.props('modelValue'));
    const certificate = wrapper.findComponent(TextArea).props('modelValue');
    return { ssoUrl, idpEntityId, certificate };
  };

  beforeEach(() => {
    errors = [];
    samlSettingsAPI.get.mockResolvedValue({ data: settings });
  });

  it('keeps SAML enabled with the unsaved draft when disabling is rejected', async () => {
    samlSettingsAPI.delete.mockRejectedValue({
      response: { status: 503, data: { errors: ['Synthetic rejection'] } },
    });
    const wrapper = await mountComponent();
    wrapper
      .findAllComponents(TextInput)[0]
      .vm.$emit('update:modelValue', 'https://draft.example.test/sso');
    await flushPromises();

    await toggle(wrapper, false);

    expect(samlSettingsAPI.delete).toHaveBeenCalledOnce();
    expect(useAlert).toHaveBeenCalledWith('Synthetic rejection');
    expect(errors).toEqual([]);
    expect(wrapper.findComponent(Switch).props('modelValue')).toBe(true);
    expect(formValues(wrapper)).toEqual({
      ssoUrl: 'https://draft.example.test/sso',
      idpEntityId: settings.idp_entity_id,
      certificate: settings.certificate,
    });
  });

  it('turns SAML off and clears the form when disabling succeeds', async () => {
    samlSettingsAPI.delete.mockResolvedValue({ data: {} });
    const wrapper = await mountComponent();

    await toggle(wrapper, false);

    expect(samlSettingsAPI.delete).toHaveBeenCalledOnce();
    expect(useAlert).toHaveBeenCalledWith(
      'SECURITY_SETTINGS.SAML.API.DISABLED'
    );
    expect(wrapper.findComponent(Switch).props('modelValue')).toBe(false);

    await toggle(wrapper, true);

    expect(errors).toEqual([]);
    expect(formValues(wrapper)).toEqual({
      ssoUrl: '',
      idpEntityId: '',
      certificate: '',
    });
  });
});
