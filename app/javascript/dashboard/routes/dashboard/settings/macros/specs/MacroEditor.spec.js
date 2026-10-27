import { mount, flushPromises } from '@vue/test-utils';
import { ref } from 'vue';
import MacroEditor from '../MacroEditor.vue';
import SingleSelect from 'dashboard/components-next/filter/inputs/SingleSelect.vue';

const fixture = vi.hoisted(() => ({ store: null, getters: null }));
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { macroId: 9 } }),
  useRouter: () => ({ push: vi.fn() }),
}));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => fixture.store,
  useStoreGetters: () => fixture.getters,
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));

describe('MacroEditor API-created actions', () => {
  let wrapper;
  afterEach(() => wrapper?.unmount());

  it.each([
    ['change_status', ['open']],
    ['change_status', ['resolved']],
    ['change_status', ['pending']],
    ['change_status', ['snoozed']],
    ['change_status', [0]],
    ['change_status', [1]],
    ['change_status', [2]],
    ['change_status', [3]],
    ['resolve_conversation', []],
    ['send_message', ['Synthetic reply']],
  ])('loads and saves %s %j unchanged', async (actionName, params) => {
    const data = {
      id: 9,
      name: 'Synthetic macro',
      visibility: 'global',
      actions: [{ action_name: actionName, action_params: params }],
    };
    fixture.getters = {
      'macros/getUIFlags': ref({ isFetchingItem: false }),
      getCurrentRole: ref('administrator'),
    };
    fixture.store = {
      dispatch: vi.fn().mockResolvedValue(),
      getters: { 'macros/getMacro': () => data },
    };
    wrapper = mount(MacroEditor, {
      global: {
        stubs: {
          WootLoadingState: true,
          WootMessageEditor: true,
          MacroProperties: {
            emits: ['submit'],
            template:
              '<button data-test="save" @click="$emit(\'submit\')">Save</button>',
          },
        },
      },
    });
    await flushPromises();
    expect(fixture.store.dispatch).toHaveBeenCalledWith(
      'macros/getSingleMacro',
      9
    );
    await wrapper.get('[data-test="save"]').trigger('click');
    await flushPromises();
    expect(fixture.store.dispatch).toHaveBeenCalledWith('macros/update', data);

    if (actionName === 'change_status') {
      const select = wrapper.findAllComponents(SingleSelect)[1];
      expect(select.props('modelValue')).toEqual([
        expect.objectContaining({ id: params[0] }),
      ]);
      const options = select.props('options');
      expect(options).toHaveLength(4);
      expect(
        options.every(option => typeof option.id === typeof params[0])
      ).toBe(true);
      // Exercise the single-object shape emitted after selecting another status,
      // including switching an integer macro back to open (0).
      const next = options.find(option => option.id !== params[0]);
      select.vm.$emit('update:modelValue', next);
      await flushPromises();
      await wrapper.get('[data-test="save"]').trigger('click');
      await flushPromises();
      const saved = {
        ...data,
        actions: [{ action_name: actionName, action_params: [next.id] }],
      };
      expect(fixture.store.dispatch).toHaveBeenLastCalledWith(
        'macros/update',
        saved
      );
      // Reload from the saved payload through the same completed route fetch.
      fixture.store.getters['macros/getMacro'] = () => saved;
      wrapper.unmount();
      wrapper = mount(MacroEditor, {
        global: {
          stubs: {
            WootLoadingState: true,
            WootMessageEditor: true,
            MacroProperties: {
              emits: ['submit'],
              template:
                '<button data-test="save" @click="$emit(\'submit\')">Save</button>',
            },
          },
        },
      });
      await flushPromises();
      expect(
        wrapper.findAllComponents(SingleSelect)[1].props('modelValue')
      ).toEqual([next]);
    }
  });
});
