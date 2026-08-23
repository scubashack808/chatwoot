import { mount } from '@vue/test-utils';
import { createStore } from 'vuex';
import ConversationBasicFilter from '../ConversationBasicFilter.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: key => key,
  }),
}));

vi.mock('@vueuse/core', async () => {
  const { ref } = await import('vue');
  return {
    useToggle: () => [ref(true), vi.fn()],
  };
});

const mountComponent = () => {
  const store = createStore({
    getters: {
      getChatStatusFilter: () => 'open',
      getChatSortFilter: () => 'last_activity_at_desc',
      getUISettings: () => ({}),
    },
    actions: {
      updateUISettings: vi.fn(),
    },
  });

  return mount(ConversationBasicFilter, {
    props: {
      isOnExpandedLayout: false,
    },
    global: {
      mocks: {
        $t: key => key,
      },
      plugins: [store],
      directives: {
        'on-click-outside': {},
      },
      stubs: {
        NextButton: {
          template:
            '<button data-testid="toggle-sort" @click="$emit(\'click\')" />',
        },
        SelectMenu: {
          name: 'SelectMenu',
          props: ['options'],
          template: '<div data-testid="select-menu" />',
        },
      },
    },
  });
};

describe('ConversationBasicFilter', () => {
  it('keeps last-inbound sorting retired and last-activity sorting available', async () => {
    const wrapper = mountComponent();
    await wrapper.get('[data-testid="toggle-sort"]').trigger('click');

    const sortOptions = wrapper
      .findAllComponents({ name: 'SelectMenu' })[1]
      .props('options')
      .map(option => option.value);

    expect(sortOptions).toContain('last_activity_at_desc');
    expect(sortOptions).not.toContain('last_inbound_at_desc');
    expect(sortOptions).not.toContain('last_inbound_at_asc');
  });
});
