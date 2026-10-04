import { config, flushPromises, shallowMount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import Response from '../Response.vue';
import Rating from '../../components/Rating.vue';
import Feedback from '../../components/Feedback.vue';
import Banner from '../../components/Banner.vue';
import en from '../../i18n/locale/en.json';
import es from '../../i18n/locale/es.json';
import { getSurveyDetails, updateSurvey } from '../../api/survey';

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

describe('survey update retry banner', () => {
  let wrapper;
  const originalPlugins = config.global.plugins;
  const failure = { response: { data: { error: 'Temporary failure' } } };

  beforeEach(async () => {
    config.global.plugins = [
      createI18n({ legacy: true, locale: 'en', messages: { en } }),
    ];
    getSurveyDetails.mockResolvedValue({
      data: {
        locale: 'en',
        inbox_name: 'Synthetic shop',
        display_type: 'emoji',
        csat_survey_response: null,
      },
    });
    updateSurvey.mockReset();
    updateSurvey.mockResolvedValue({ data: {} });
    wrapper = shallowMount(Response, {
      global: {
        directives: { 'dompurify-html': () => {} },
        stubs: { Banner: false },
      },
    });
    await flushPromises();
  });

  afterEach(() => {
    wrapper?.unmount();
    config.global.plugins = originalPlugins;
  });

  const rate = async () => {
    wrapper.findComponent(Rating).vm.$emit('selectRating', 5);
    await flushPromises();
  };
  const sendFeedback = async () => {
    wrapper.findComponent(Feedback).vm.$emit('sendFeedback', 'Great trip');
    await flushPromises();
  };
  const bannerState = () => {
    const banner = wrapper.findComponent(Banner);
    return {
      text: banner.text(),
      successIcons: banner.findAll('.ion-checkmark-circled').length,
      errorIcons: banner.findAll('.ion-android-alert').length,
    };
  };
  const success = {
    text: en.SURVEY.RATING.SUCCESS_MESSAGE,
    successIcons: 1,
    errorIcons: 0,
  };

  it('shows only success after a first successful rating', async () => {
    await rate();
    expect(bannerState()).toEqual(success);
  });

  it('replaces the failure with success after a rating retry succeeds', async () => {
    updateSurvey.mockRejectedValueOnce(failure);
    await rate();
    expect(wrapper.vm.isUpdating).toBe(false);
    expect(bannerState()).toEqual({
      text: 'Temporary failure',
      successIcons: 0,
      errorIcons: 1,
    });

    await rate();
    expect(updateSurvey).toHaveBeenCalledTimes(2);
    expect(bannerState()).toEqual(success);
  });

  it('replaces the failure with success after a feedback retry succeeds', async () => {
    await rate();
    updateSurvey.mockRejectedValueOnce(failure);
    await sendFeedback();
    expect(wrapper.vm.hasSubmittedFeedback).toBe(false);
    expect(bannerState().errorIcons).toBe(1);

    await sendFeedback();
    expect(wrapper.vm.hasSubmittedFeedback).toBe(true);
    expect(bannerState()).toEqual(success);
  });

  it('keeps the error and allows retry while updates keep failing', async () => {
    updateSurvey.mockRejectedValue(failure);
    await rate();
    await rate();
    expect(updateSurvey).toHaveBeenCalledTimes(2);
    expect(wrapper.vm.isUpdating).toBe(false);
    expect(bannerState()).toEqual({
      text: 'Temporary failure',
      successIcons: 0,
      errorIcons: 1,
    });
  });
});
