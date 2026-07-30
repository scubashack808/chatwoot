import { ref } from 'vue';
import { mount } from '@vue/test-utils';
import { useMessageContext } from '../provider.js';
import MessageError from '../MessageError.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

vi.mock('../provider.js', () => ({
  useMessageContext: vi.fn(),
}));

const mountMessageError = retryDisabled => {
  useMessageContext.mockReturnValue({
    orientation: ref('right'),
    status: ref('failed'),
    createdAt: ref(Math.floor(Date.now() / 1000)),
    content: ref('test'),
    attachments: ref([]),
    contentAttributes: ref({ rcRetryDisabled: retryDisabled }),
  });

  return mount(MessageError, {
    props: { error: 'Send failed' },
    global: {
      stubs: { Icon: true },
    },
  });
};

describe('MessageError', () => {
  it('hides retry for a terminal RingCentral failure', () => {
    const wrapper = mountMessageError(true);

    expect(wrapper.find('button').exists()).toBe(false);
    expect(wrapper.text()).toContain('CHAT_LIST.FAILED_TO_SEND');
  });

  it('retains upstream retry for other failures', () => {
    const wrapper = mountMessageError(false);

    expect(wrapper.find('button').exists()).toBe(true);
  });
});
