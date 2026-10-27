import { mount, flushPromises } from '@vue/test-utils';
import { createRouter, createMemoryHistory } from 'vue-router';
import { createStore } from 'vuex';
import { nextTick } from 'vue';
import { it, expect, vi, afterEach } from 'vitest';
import { routes as contactRoutes } from 'dashboard/routes/dashboard/contacts/routes';
import ContactsIndex from 'dashboard/routes/dashboard/contacts/pages/ContactsIndex.vue';
import Dashboard from 'dashboard/routes/dashboard/Dashboard.vue';
import contactsModule from 'dashboard/store/modules/contacts';
import { frontendURL } from 'dashboard/helper/URLHelper';

// Peripheral UI only. Actual router views, ContactsIndex, contacts store,
// API builder, ContactsListLayout and ContactsList remain unmodified imports.
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/stores/calls', () => ({
  useCallsStore: () => ({ hasActiveCall: false, hasIncomingCall: false }),
}));
vi.mock('next/sidebar/Sidebar.vue', () => ({
  default: { template: '<aside />' },
}));
vi.mock('dashboard/components/widgets/modal/WootKeyShortcutModal.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock('dashboard/components/app/AddAccountModal.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock('dashboard/routes/dashboard/upgrade/UpgradePage.vue', () => ({
  default: {
    data: () => ({ shouldShowUpgradePage: false, isAccountPaywalled: false }),
    template: '<div />',
  },
}));
vi.mock('dashboard/components-next/copilot/CopilotLauncher.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock('dashboard/components/copilot/CopilotContainer.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock('dashboard/components-next/sidebar/MobileSidebarLauncher.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock('dashboard/routes/dashboard/commands/commandbar.vue', () => ({
  __esModule: true,
  default: { template: '<div />' },
}));
vi.mock(
  'dashboard/routes/dashboard/contacts/pages/ContactManageView.vue',
  () => ({ default: { template: '<div />' } })
);
vi.mock(
  'dashboard/components-next/Contacts/EmptyState/ContactEmptyState.vue',
  () => ({ default: { template: '<div />' } })
);
vi.mock(
  'dashboard/routes/dashboard/contacts/components/ContactsBulkActionBar.vue',
  () => ({ default: { template: '<div />' } })
);
vi.mock('dashboard/components-next/dialog/Dialog.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock(
  'dashboard/components-next/Contacts/ContactsHeader/ContactListHeaderWrapper.vue',
  () => ({
    default: { props: ['headerTitle'], template: '<h1>{{headerTitle}}</h1>' },
  })
);
vi.mock(
  'dashboard/components-next/Contacts/ContactsHeader/components/ContactsActiveFiltersPreview.vue',
  () => ({ default: { template: '<div />' } })
);
vi.mock('dashboard/components-next/pagination/PaginationFooter.vue', () => ({
  default: { template: '<footer />' },
}));
vi.mock('dashboard/components-next/Contacts/ContactsLoadMore.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock(
  'dashboard/components-next/Contacts/ContactsCard/ContactsCard.vue',
  () => ({
    default: {
      props: ['id', 'name'],
      template: '<article class="contact" :data-id="id">{{name}}</article>',
    },
  })
);

let wrapper;
afterEach(() => {
  wrapper?.unmount();
  vi.unstubAllGlobals();
});

it.each(['pending-switch', 'late-a', 'completed-switch', 'fresh-b'])(
  'contact label navigation: %s',
  async scenario => {
    window.history.replaceState({}, '', '/app/accounts/1/contacts');
    const requests = [];
    const axios = {
      get: vi.fn(
        (url, config) =>
          new Promise(resolve => {
            requests.push({ url, config, resolve });
          })
      ),
    };
    vi.stubGlobal('axios', axios);
    const store = createStore({
      state: () => ({ uiSettings: {} }),
      getters: { getUISettings: state => state.uiSettings },
      actions: {
        updateUISettings: ({ state }, { uiSettings }) => {
          state.uiSettings = uiSettings;
        },
      },
      modules: {
        contacts: {
          ...contactsModule,
          state: () => JSON.parse(JSON.stringify(contactsModule.state)),
        },
        customViews: {
          namespaced: true,
          getters: {
            getUIFlags: () => ({ isFetching: false }),
            getContactCustomViews: () => [],
          },
        },
      },
    });
    // This is the actual dashboard parent record shape, restricted to the actual
    // imported contacts route records. No route key or forced remount is added.
    const router = createRouter({
      history: createMemoryHistory(),
      routes: [
        {
          path: frontendURL('accounts/:accountId'),
          component: Dashboard,
          children: contactRoutes,
        },
      ],
    });
    const target = label => ({
      name: 'contacts_dashboard_labels_index',
      params: { accountId: '1', label },
      query: { page: '1' },
    });
    await router.push(target(scenario === 'fresh-b' ? 'label-b' : 'label-a'));
    await router.isReady();
    wrapper = mount(
      {
        template:
          "<div><RouterLink class=\"label-b-link\" :to=\"{ name: 'contacts_dashboard_labels_index', params: { accountId: '1', label: 'label-b' }, query: { page: '1' } }\">Label B</RouterLink><RouterView /></div>",
      },
      { global: { plugins: [store, router], stubs: { CommandBar: true } } }
    );
    await flushPromises();
    expect(wrapper.findAllComponents(ContactsIndex)).toHaveLength(1);
    const originalInstanceUid = wrapper.findComponent(ContactsIndex).vm.$.uid;
    expect(requests).toHaveLength(1);
    const firstLabel = scenario === 'fresh-b' ? 'label-b' : 'label-a';
    expect(requests[0].config.params.labels).toEqual([firstLabel]);
    expect(requests[0].url).toBe('/api/v1/accounts/1/contacts');
    expect(store.state.contacts.uiFlags.isFetching).toBe(true);

    if (scenario === 'pending-switch' || scenario === 'late-a') {
      await wrapper.get('a.label-b-link').trigger('click');
      await flushPromises();
      expect(router.currentRoute.value.params.label).toBe('label-b');
      expect(wrapper.findComponent(ContactsIndex).vm.$.uid).toBe(
        originalInstanceUid
      );
      expect(wrapper.get('h1').text()).toBe('#label-b');
      expect(requests).toHaveLength(2);
      expect(requests[1].config.params.labels).toEqual(['label-b']);
      if (scenario === 'late-a') {
        requests[1].resolve({
          data: {
            payload: [{ id: 202, name: 'Contact from label-b' }],
            meta: { count: 1, current_page: 1, has_more: false },
          },
        });
        await flushPromises();
      }
    }

    requests[0].resolve({
      data: {
        payload: [
          {
            id: firstLabel === 'label-a' ? 101 : 202,
            name: `Contact from ${firstLabel}`,
          },
        ],
        meta: {
          count: firstLabel === 'label-a' ? 99 : 1,
          current_page: 1,
          has_more: false,
        },
      },
    });
    await flushPromises();
    await nextTick();
    if (scenario === 'pending-switch') {
      expect(store.state.contacts.uiFlags.isFetching).toBe(true);
      requests[1].resolve({
        data: {
          payload: [{ id: 202, name: 'Contact from label-b' }],
          meta: { count: 1, current_page: 1, has_more: false },
        },
      });
      await flushPromises();
    }
    if (scenario === 'completed-switch' || scenario === 'fresh-b') {
      expect(store.state.contacts.uiFlags.isFetching).toBe(false);
      expect(wrapper.get('.contact').text()).toBe(`Contact from ${firstLabel}`);
    }

    if (scenario === 'completed-switch') {
      expect(wrapper.get('h1').text()).toBe('#label-a');
      await wrapper.get('a.label-b-link').trigger('click');
      await flushPromises();
      expect(wrapper.findComponent(ContactsIndex).vm.$.uid).toBe(
        originalInstanceUid
      );
      expect(requests).toHaveLength(2);
      expect(requests[1].config.params.labels).toEqual(['label-b']);
      requests[1].resolve({
        data: {
          payload: [{ id: 202, name: 'Contact from label-b' }],
          meta: { count: 1, current_page: 1, has_more: false },
        },
      });
      await flushPromises();
    }

    // Extra microtask/router completion turns ensure no deferred B reload is
    // merely waiting behind the earlier response's updatePageParam replacement.
    await flushPromises();
    await nextTick();
    expect(store.state.contacts.uiFlags.isFetching).toBe(false);
    expect(store.state.contacts.meta).toMatchObject({
      count: 1,
      currentPage: 1,
    });
    expect(router.currentRoute.value.params.label).toBe('label-b');
    expect(wrapper.get('h1').text()).toBe('#label-b');
    expect(wrapper.get('.contact').text()).toBe('Contact from label-b');
    expect(requests.map(r => r.config.params.labels[0])).toEqual(
      scenario === 'fresh-b' ? ['label-b'] : ['label-a', 'label-b']
    );
  }
);
