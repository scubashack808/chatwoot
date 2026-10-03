import { mount, flushPromises } from '@vue/test-utils';
import { ref, reactive, computed } from 'vue';
import Index from '../Index.vue';
import EditAutomationRule from '../EditAutomationRule.vue';
import AutomationRuleForm from '../AutomationRuleForm.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import { validateActions } from 'dashboard/helper/validations';
import { actions, mutations } from 'dashboard/store/modules/sla';
import SlaAPI from 'dashboard/api/sla';

const fixture = vi.hoisted(() => ({
  store: null,
  getters: null,
  open: vi.fn(),
}));

vi.mock('dashboard/composables/store', () => ({
  useStore: () => fixture.store,
  useStoreGetters: () => fixture.getters,
  useMapGetter: name => fixture.getters[name],
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/api/sla', () => ({ default: { get: vi.fn() } }));
vi.mock('../AutomationRuleForm.vue', () => ({
  default: {
    name: 'AutomationRuleForm',
    props: ['automation', 'getActionDropdownValues'],
    methods: { open: fixture.open, close() {} },
    template: '<div />',
  },
}));
vi.mock('../AddAutomationRule.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock('../../SettingsLayout.vue', () => ({
  default: {
    template: '<main><slot name="header"/><slot name="body"/><slot/></main>',
  },
}));
vi.mock('../../components/BaseSettingsHeader.vue', () => ({
  default: { template: '<div><slot name="tabs"/></div>' },
}));
vi.mock('dashboard/components-next/table', () => ({
  BaseTable: {
    props: ['items'],
    template: '<div><slot name="row" :items="items"/></div>',
  },
}));
vi.mock('../AutomationRuleRow.vue', () => ({
  default: {
    name: 'AutomationRuleRow',
    props: ['automation'],
    emits: ['edit'],
    template:
      '<button class="edit" @click="$emit(\'edit\', automation)">Edit</button>',
  },
}));

describe('opening an automation with SLA actions', () => {
  let wrapper;
  let rule;
  let sla;
  let resolveSLA;

  beforeEach(() => {
    rule = {
      id: 7,
      name: 'Synthetic rule',
      event_name: 'conversation_created',
      active: true,
      conditions: [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: ['open'],
          query_operator: 'and',
        },
      ],
      actions: [{ action_name: 'add_sla', action_params: [42] }],
    };
    sla = reactive({ records: [], uiFlags: { isFetching: false } });
    fixture.getters = Object.fromEntries(
      [
        'attributes/getAttributes',
        'agents/getVerifiedAgents',
        'campaigns/getAllCampaigns',
        'contacts/getContacts',
        'inboxes/getInboxes',
        'labels/getLabels',
        'teams/getTeams',
      ].map(key => [key, ref([])])
    );
    Object.assign(fixture.getters, {
      'sla/getSLA': computed(() => sla.records),
      'attributes/getAttributesByModel': ref(() => []),
      'automations/getAutomations': ref([rule]),
      'automations/getUIFlags': ref({}),
      getCurrentAccountId: ref(1),
      'accounts/isFeatureEnabledonAccount': ref((id, flag) => flag === 'sla'),
    });
    SlaAPI.get.mockImplementation(
      () =>
        new Promise(resolve => {
          resolveSLA = resolve;
        })
    );
    fixture.store = {
      dispatch: vi.fn(name =>
        name === 'sla/get'
          ? actions.get({
              commit: (type, value) => mutations[type](sla, value),
            })
          : Promise.resolve()
      ),
    };
  });

  afterEach(() => wrapper?.unmount());

  it.each([false, true])(
    'preserves the saved policy and fields with SLA loaded first=%s',
    async loadedFirst => {
      const original = JSON.parse(JSON.stringify(rule));
      const policy = { id: 42, name: 'Synthetic SLA' };
      wrapper = mount(Index, {
        global: {
          stubs: {
            Button: true,
            TabBar: true,
            WootDeleteModal: true,
            WootConfirmModal: true,
          },
        },
      });
      expect(sla.uiFlags.isFetching).toBe(true);
      if (loadedFirst) {
        resolveSLA({ data: { payload: [policy] } });
        await flushPromises();
      }
      await wrapper.get('button.edit').trigger('click');
      if (!loadedFirst) {
        expect(fixture.open).not.toHaveBeenCalled();
        expect(
          wrapper.findComponent(EditAutomationRule).props('selectedResponse')
        ).toEqual({});
        resolveSLA({ data: { payload: [policy] } });
      }
      await flushPromises();
      const form = wrapper
        .findComponent(EditAutomationRule)
        .findComponent(AutomationRuleForm);
      expect(fixture.open).toHaveBeenCalledTimes(1);
      expect(form.props('getActionDropdownValues')('add_sla')).toEqual([
        policy,
      ]);
      expect(form.props('automation')).toMatchObject({
        id: rule.id,
        name: rule.name,
        event_name: rule.event_name,
        active: rule.active,
        conditions: [
          {
            attribute_key: 'status',
            filter_operator: 'equal_to',
            query_operator: 'and',
            values: [{ id: 'open' }],
          },
        ],
        actions: [{ action_name: 'add_sla', action_params: [policy] }],
      });
      expect(validateActions(form.props('automation').actions)).toEqual({});
      await wrapper.get('button.edit').trigger('click');
      await flushPromises();
      expect(fixture.open).toHaveBeenCalledTimes(2);
      expect(form.props('automation').actions[0].action_params).toEqual([
        policy,
      ]);
      expect(validateActions(form.props('automation').actions)).toEqual({});
      expect(SlaAPI.get).toHaveBeenCalledTimes(1);
      expect(rule).toEqual(original);
    }
  );

  it('opens immediately without requesting SLA when the feature is disabled', async () => {
    fixture.getters['accounts/isFeatureEnabledonAccount'] = ref(() => false);
    rule.actions = [{ action_name: 'resolve_conversation', action_params: [] }];
    wrapper = mount(Index, {
      global: {
        stubs: {
          Button: true,
          TabBar: true,
          WootDeleteModal: true,
          WootConfirmModal: true,
        },
      },
    });
    await wrapper.get('button.edit').trigger('click');
    expect(fixture.open).toHaveBeenCalledTimes(1);
    expect(SlaAPI.get).not.toHaveBeenCalled();
    expect(fixture.store.dispatch).not.toHaveBeenCalledWith('sla/get');
    const form = wrapper.findComponent(AutomationRuleForm);
    expect(form.props('automation').actions).toEqual(rule.actions);
    expect(validateActions(form.props('automation').actions)).toEqual({});
  });

  it('hydrates the execution delay of each selected rule after loading', async () => {
    rule.execution_delay = 15;
    const secondRule = {
      ...rule,
      id: 8,
      name: 'Second rule',
      execution_delay: 30,
    };
    fixture.getters['automations/getAutomations'] = ref([rule, secondRule]);
    wrapper = mount(Index, {
      global: {
        stubs: {
          Button: true,
          TabBar: true,
          WootDeleteModal: true,
          WootConfirmModal: true,
        },
      },
    });
    resolveSLA({ data: { payload: [{ id: 42, name: 'Synthetic SLA' }] } });
    await flushPromises();
    wrapper.findComponent(TabBar).vm.$emit('tabChanged', { key: 'delayed' });
    await flushPromises();
    const buttons = wrapper.findAll('button.edit');
    await buttons[0].trigger('click');
    await flushPromises();
    expect(fixture.open).toHaveBeenLastCalledWith(15);
    await buttons[1].trigger('click');
    await flushPromises();
    expect(fixture.open).toHaveBeenLastCalledWith(30);
    expect(
      wrapper.findComponent(AutomationRuleForm).props('automation')
    ).toMatchObject({
      id: 8,
      name: 'Second rule',
      execution_delay: 30,
      actions: [
        {
          action_name: 'add_sla',
          action_params: [{ id: 42, name: 'Synthetic SLA' }],
        },
      ],
    });
    expect(SlaAPI.get).toHaveBeenCalledTimes(1);
  });
});
