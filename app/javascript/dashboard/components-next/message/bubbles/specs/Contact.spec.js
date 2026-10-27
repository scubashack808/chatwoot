import { defineComponent, h, ref } from 'vue';
import { shallowMount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';
import axios from 'axios';
import { useCamelCase } from 'dashboard/composables/useTransformKeys';
import contacts from 'dashboard/store/modules/contacts';
import { useAlert } from 'dashboard/composables';
import Contact from '../Contact.vue';
import BaseAttachment from '../BaseAttachment.vue';
import { provideMessageContext } from '../../provider';

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/helper/AnalyticsHelper', () => ({
  default: { track: vi.fn() },
}));

describe('Contact saving through the contacts API', () => {
  let wrapper;
  let store;
  let adapter;
  let postSpy;
  let existing;
  let originalPath;

  const mountContact = (phone = '+1 808-555-0123') => {
    const attachments = useCamelCase(
      [
        {
          id: 1,
          file_type: 'contact',
          fallback_title: phone,
          meta: { first_name: 'Synthetic', last_name: 'Diver' },
        },
      ],
      { deep: true }
    );
    wrapper = shallowMount(
      defineComponent({
        setup() {
          provideMessageContext({
            attachments: ref(attachments),
            sender: ref({ name: 'Visitor' }),
          });
          return () => h(Contact);
        },
      }),
      {
        global: {
          plugins: [store],
          stubs: { Contact: false },
        },
      }
    );
    return wrapper.findComponent(BaseAttachment);
  };

  beforeEach(() => {
    originalPath = window.location.href;
    window.history.replaceState({}, '', '/app/accounts/1/dashboard');
    existing = true;
    adapter = vi.fn(async config => {
      const body = JSON.parse(config.data);
      if (config.url.endsWith('/filter')) {
        const matches = body.payload[0].values[0] === '18085550123';
        return {
          data: {
            payload: existing && matches ? [{ id: 77 }] : [],
            meta: {},
          },
          status: 200,
          headers: {},
          config,
        };
      }
      if (existing) {
        throw new axios.AxiosError(
          'Duplicate phone',
          'ERR_BAD_REQUEST',
          config,
          null,
          {
            status: 422,
            data: { attributes: ['phone_number'] },
          }
        );
      }
      return {
        data: { payload: { contact: { id: 88, ...body } } },
        status: 200,
        headers: {},
        config,
      };
    });
    const http = axios.create({ adapter });
    postSpy = vi.spyOn(http, 'post');
    vi.stubGlobal('axios', http);
    vi.spyOn(window, 'open').mockImplementation(() => null);
    store = createStore({
      modules: {
        contacts: {
          ...contacts,
          state: JSON.parse(JSON.stringify(contacts.state)),
        },
      },
    });
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    window.history.replaceState({}, '', originalPath);
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it('serializes the phone and opens an existing contact without creating', async () => {
    const bubble = mountContact();
    await bubble.props('action').onClick();
    await flushPromises();

    expect(adapter).toHaveBeenCalledTimes(1);
    const request = adapter.mock.calls[0][0];
    expect(request.url).toMatch(/\/filter$/);
    expect(JSON.parse(request.data).payload[0].values).toEqual(['18085550123']);
    expect(postSpy).toHaveBeenCalledTimes(1);
    expect(window.open).toHaveBeenCalledExactlyOnceWith(
      '/app/accounts/1/contacts/77',
      '_blank'
    );
    expect(useAlert).not.toHaveBeenCalled();
  });

  it('filters before creating and opening a genuinely new contact', async () => {
    existing = false;
    const bubble = mountContact();
    await bubble.props('action').onClick();
    await flushPromises();

    expect(adapter).toHaveBeenCalledTimes(2);
    expect(postSpy).toHaveBeenCalledTimes(2);
    const [filter, create] = adapter.mock.calls.map(([config]) => config);
    expect(filter.url).toMatch(/\/filter$/);
    expect(JSON.parse(filter.data).payload[0].values).toEqual(['18085550123']);
    expect(create.url).toMatch(/\/contacts$/);
    expect(JSON.parse(create.data)).toEqual({
      name: 'Synthetic Diver',
      phone_number: '+18085550123',
    });
    expect(window.open).toHaveBeenCalledExactlyOnceWith(
      '/app/accounts/1/contacts/88',
      '_blank'
    );
    expect(useAlert).toHaveBeenCalledExactlyOnceWith(
      'CONTACT_FORM.SUCCESS_MESSAGE'
    );
  });

  it('hides the save action for an empty phone', () => {
    const bubble = mountContact('');
    expect(bubble.props('action')).toBeNull();
    expect(postSpy).not.toHaveBeenCalled();
    expect(adapter).not.toHaveBeenCalled();
    expect(window.open).not.toHaveBeenCalled();
  });

  it('finds a literal phone through the real store and API', async () => {
    const result = await store.dispatch('contacts/filter', {
      resetState: false,
      queryPayload: {
        payload: [
          {
            attribute_key: 'phone_number',
            filter_operator: 'equal_to',
            values: ['18085550123'],
            attribute_model: 'standard',
            custom_attribute_type: '',
          },
        ],
      },
    });
    expect(result).toEqual([{ id: 77 }]);
    expect(adapter).toHaveBeenCalledTimes(1);
    expect(JSON.parse(adapter.mock.calls[0][0].data).payload[0].values).toEqual(
      ['18085550123']
    );
  });
});
