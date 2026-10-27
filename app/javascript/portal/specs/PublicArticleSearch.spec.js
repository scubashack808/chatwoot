import {
  enableAutoUnmount,
  flushPromises,
  shallowMount,
} from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import PublicArticleSearch from '../components/PublicArticleSearch.vue';
import ArticlesAPI from '../api/article';

vi.mock('../api/article', () => ({
  default: {
    searchArticles: vi.fn(),
  },
}));

enableAutoUnmount(afterEach);

describe('PublicArticleSearch', () => {
  let originalPortalConfig;
  let requests;
  const SearchSuggestionsStub = {
    name: 'SearchSuggestions',
    template: '<div />',
    props: ['searchTerm', 'items', 'isLoading'],
  };

  beforeEach(() => {
    vi.useFakeTimers();
    requests = [];
    ArticlesAPI.searchArticles.mockImplementation(
      (portal, locale, query) =>
        new Promise((resolve, reject) => {
          requests.push({ query, resolve, reject });
        })
    );
    originalPortalConfig = window.portalConfig;
    window.portalConfig = {
      portalSlug: 'test-portal',
      localeCode: 'en',
      searchTranslations: {},
    };
  });

  afterEach(() => {
    vi.clearAllMocks();
    vi.useRealTimers();
    window.portalConfig = originalPortalConfig;
  });

  const buildWrapper = () =>
    shallowMount(PublicArticleSearch, {
      global: {
        directives: {
          onClickaway: () => {},
        },
        stubs: {
          SearchSuggestions: SearchSuggestionsStub,
          PublicSearchInput: true,
        },
      },
    });

  it.each([
    [0, 1],
    [1, 0],
  ])(
    'retains parking suggestions when requests settle in order %s, %s',
    async (first, second) => {
      const wrapper = buildWrapper();
      const input = wrapper.findComponent({ name: 'PublicSearchInput' });
      input.vm.$emit('update:search-term', 'refund');
      await vi.advanceTimersByTimeAsync(1000);
      input.vm.$emit('update:search-term', 'parking');
      await vi.advanceTimersByTimeAsync(1000);
      expect(requests.map(request => request.query)).toEqual([
        'refund',
        'parking',
      ]);

      requests[first].resolve({
        data: { payload: [{ id: first + 1, title: requests[first].query }] },
      });
      await flushPromises();
      expect(wrapper.vm.isLoading).toBe(first === 0);
      requests[second].resolve({
        data: { payload: [{ id: second + 1, title: requests[second].query }] },
      });
      await flushPromises();

      expect(
        wrapper.findComponent(SearchSuggestionsStub).props()
      ).toMatchObject({
        searchTerm: 'parking',
        items: [{ id: 2, title: 'parking' }],
        isLoading: false,
      });
    }
  );

  it.each([
    ['resolve', 0],
    ['reject', 0],
    ['resolve', 1000],
    ['reject', 1000],
  ])(
    'keeps loading when an obsolete request %ss after %s ms',
    async (settle, delay) => {
      const wrapper = buildWrapper();
      const input = wrapper.findComponent({ name: 'PublicSearchInput' });
      input.vm.$emit('update:search-term', 'refund');
      await vi.advanceTimersByTimeAsync(1000);
      input.vm.$emit('update:search-term', 'parking');
      await vi.advanceTimersByTimeAsync(delay);
      if (settle === 'resolve') {
        requests[0].resolve({
          data: { payload: [{ id: 1, title: 'refund' }] },
        });
      } else {
        requests[0].reject(new Error('Obsolete request failed'));
      }
      await flushPromises();
      expect(
        wrapper.findComponent(SearchSuggestionsStub).props()
      ).toMatchObject({
        searchTerm: 'parking',
        items: [],
        isLoading: true,
      });
      await vi.advanceTimersByTimeAsync(1000 - delay);
      requests[1].resolve({ data: { payload: [{ id: 2, title: 'parking' }] } });
      await flushPromises();
      expect(wrapper.vm.isLoading).toBe(false);
      expect(wrapper.vm.searchResults).toEqual([{ id: 2, title: 'parking' }]);
    }
  );

  it.each(['', '   ', 'programmatic'])(
    'invalidates pending requests when clearing with %j',
    async clearValue => {
      const wrapper = buildWrapper();
      const input = wrapper.findComponent({ name: 'PublicSearchInput' });
      input.vm.$emit('update:search-term', 'refund');
      await vi.advanceTimersByTimeAsync(1000);
      if (clearValue === 'programmatic') {
        wrapper.vm.clearSearchTerm();
      } else {
        input.vm.$emit('update:search-term', clearValue);
      }
      requests[0].resolve({ data: { payload: [{ id: 1 }] } });
      await flushPromises();
      expect(wrapper.vm.searchResults).toEqual([]);
      expect(wrapper.vm.isLoading).toBe(false);
      expect(wrapper.findComponent(SearchSuggestionsStub).exists()).toBe(false);
    }
  );

  it.each(['', '   ', 'programmatic'])(
    'cancels an unsent debounce when clearing with %j',
    async clearValue => {
      const wrapper = buildWrapper();
      const input = wrapper.findComponent({ name: 'PublicSearchInput' });
      input.vm.$emit('update:search-term', 'refund');
      await vi.advanceTimersByTimeAsync(500);
      if (clearValue === 'programmatic') {
        wrapper.vm.clearSearchTerm();
      } else {
        input.vm.$emit('update:search-term', clearValue);
      }
      await vi.advanceTimersByTimeAsync(1000);
      expect(ArticlesAPI.searchArticles).not.toHaveBeenCalled();
      expect(wrapper.vm.isLoading).toBe(false);
      expect(wrapper.findComponent(SearchSuggestionsStub).exists()).toBe(false);
    }
  );

  it('distinguishes separate requests for the same query', async () => {
    const wrapper = buildWrapper();
    const input = wrapper.findComponent({ name: 'PublicSearchInput' });
    input.vm.$emit('update:search-term', 'refund');
    await vi.advanceTimersByTimeAsync(1000);
    input.vm.$emit('update:search-term', 'parking');
    await vi.advanceTimersByTimeAsync(1000);
    input.vm.$emit('update:search-term', 'refund');
    await vi.advanceTimersByTimeAsync(1000);
    requests[2].resolve({
      data: { payload: [{ id: 3, title: 'New refund' }] },
    });
    await flushPromises();
    requests[0].resolve({
      data: { payload: [{ id: 1, title: 'Old refund' }] },
    });
    requests[1].resolve({ data: { payload: [{ id: 2, title: 'parking' }] } });
    await flushPromises();
    expect(wrapper.findComponent(SearchSuggestionsStub).props('items')).toEqual(
      [{ id: 3, title: 'New refund' }]
    );
  });

  it('finishes loading when the current request fails', async () => {
    const wrapper = buildWrapper();
    wrapper
      .findComponent({ name: 'PublicSearchInput' })
      .vm.$emit('update:search-term', 'refund');
    await vi.advanceTimersByTimeAsync(1000);
    requests[0].reject(new Error('Current request failed'));
    await flushPromises();
    expect(wrapper.vm.isLoading).toBe(false);
    expect(wrapper.vm.searchResults).toEqual([]);
  });

  it('keeps request ownership independent between portal instances', async () => {
    const first = buildWrapper();
    const second = buildWrapper();
    first.vm.onUpdateSearchTerm('refund');
    await vi.advanceTimersByTimeAsync(1000);
    second.vm.onUpdateSearchTerm('parking');
    await vi.advanceTimersByTimeAsync(1000);
    second.vm.onUpdateSearchTerm('parking updated');
    requests[0].resolve({ data: { payload: [{ id: 1 }] } });
    await flushPromises();
    expect(first.vm.searchResults).toEqual([{ id: 1 }]);
    expect(first.vm.isLoading).toBe(false);
    expect(second.vm.isLoading).toBe(true);
  });

  it('does not mutate search state when a request resolves after unmount', async () => {
    const wrapper = buildWrapper();
    wrapper.vm.onUpdateSearchTerm('refund');
    await vi.advanceTimersByTimeAsync(1000);
    const state = wrapper.vm.$data;
    wrapper.unmount();
    requests[0].resolve({ data: { payload: [{ id: 1 }] } });
    await flushPromises();
    expect(state.searchResults).toEqual([]);
    expect(state.isLoading).toBe(true);
  });

  it('allows a current request to complete while the dropdown is closed', async () => {
    const wrapper = buildWrapper();
    wrapper.vm.onUpdateSearchTerm('refund');
    await vi.advanceTimersByTimeAsync(1000);
    wrapper.vm.closeSearch();
    requests[0].resolve({ data: { payload: [{ id: 1 }] } });
    await flushPromises();
    expect(wrapper.vm.searchResults).toEqual([{ id: 1 }]);
    expect(wrapper.vm.isLoading).toBe(false);
    expect(wrapper.findComponent(SearchSuggestionsStub).exists()).toBe(false);
  });

  it('does not fetch or show suggestions for whitespace-only search terms', async () => {
    const wrapper = buildWrapper();
    wrapper.vm.searchResults = [{ id: 1 }];
    wrapper.vm.showSearchBox = true;

    wrapper.vm.onUpdateSearchTerm('   ');
    await wrapper.vm.$nextTick();
    vi.runAllTimers();
    await flushPromises();

    expect(ArticlesAPI.searchArticles).not.toHaveBeenCalled();
    expect(wrapper.vm.searchResults).toEqual([]);
    expect(wrapper.vm.shouldShowSearchBox).toBe(false);
    expect(wrapper.vm.isLoading).toBe(false);
  });

  it('trims the search term before requesting articles', async () => {
    ArticlesAPI.searchArticles.mockResolvedValue({ data: { payload: [] } });
    const wrapper = buildWrapper();

    wrapper.vm.onUpdateSearchTerm('  chatwoot  ');
    vi.runAllTimers();
    await flushPromises();

    expect(ArticlesAPI.searchArticles).toHaveBeenCalledWith(
      'test-portal',
      'en',
      'chatwoot'
    );
  });

  it('passes the trimmed search term to suggestions for highlighting', async () => {
    const wrapper = buildWrapper();

    wrapper.vm.onUpdateSearchTerm('  chatwoot  ');
    await wrapper.vm.$nextTick();

    expect(
      wrapper.findComponent(SearchSuggestionsStub).props('searchTerm')
    ).toBe('chatwoot');
  });
});
