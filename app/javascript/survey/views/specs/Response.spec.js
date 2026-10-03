import { config, flushPromises, shallowMount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import Response from '../Response.vue';
import en from '../../i18n/locale/en.json';
import es from '../../i18n/locale/es.json';
import { getSurveyDetails } from '../../api/survey';

vi.mock('../../api/survey', () => ({
  getSurveyDetails: vi.fn(),
  updateSurvey: vi.fn(),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('shared/composables/useMessageFormatter', () => ({
  useMessageFormatter: () => ({ formatMessage: value => value }),
}));

describe('survey introduction locale', () => {
  let wrapper;
  const originalPlugins = config.global.plugins;

  afterEach(() => {
    wrapper?.unmount();
    config.global.plugins = originalPlugins;
  });

  it.each([
    ['Spanish default', 'es', null, null],
    ['English default', 'en', null, null],
    ['custom message', 'es', 'Mensaje personalizado', null],
    ['submitted survey', 'es', null, { rating: 5 }],
    ['empty custom message', 'es', '', null],
    ['missing locale', undefined, null, null],
  ])('preserves %s behavior', async (_, locale, content, response) => {
    const i18n = createI18n({
      legacy: true,
      locale: 'en',
      messages: { en, es },
    });
    config.global.plugins = [i18n];
    getSurveyDetails.mockResolvedValue({
      data: {
        locale,
        content,
        inbox_name: 'Synthetic shop',
        inbox_avatar_url: null,
        display_type: 'emoji',
        csat_survey_response: response,
      },
    });
    wrapper = shallowMount(Response, {
      global: {
        directives: {
          'dompurify-html': (element, binding) => {
            element.textContent = binding.value;
          },
        },
      },
    });
    await flushPromises();

    expect(wrapper.vm.errorMessage).toBeNull();
    expect(i18n.global.locale).toBe(locale || 'en');
    const catalog = locale === 'es' ? es : en;
    if (response) {
      expect(wrapper.find('.prose-bubble').exists()).toBe(false);
      expect(wrapper.find('label').exists()).toBe(false);
    } else {
      const introduction =
        content ||
        catalog.SURVEY.DESCRIPTION.replace('{inboxName}', 'Synthetic shop');
      expect(wrapper.get('label').text()).toBe(catalog.SURVEY.RATING.LABEL);
      expect(wrapper.get('.prose-bubble').text()).toBe(introduction);
      expect(wrapper.vm.messageContent).toBe(introduction);
    }
  });
});
