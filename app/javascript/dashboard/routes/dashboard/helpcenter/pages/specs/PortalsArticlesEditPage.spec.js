import { mount, flushPromises } from '@vue/test-utils';
import { reactive, computed, nextTick } from 'vue';
import Page from '../PortalsArticlesEditPage.vue';
import ArticleEditor from 'dashboard/components-next/HelpCenter/Pages/ArticleEditorPage/ArticleEditor.vue';
import ArticleEditorControls from 'dashboard/components-next/HelpCenter/Pages/ArticleEditorPage/ArticleEditorControls.vue';
import { actions } from 'dashboard/store/modules/helpCenterArticles/actions';
import { mutations } from 'dashboard/store/modules/helpCenterArticles/mutations';
import articlesAPI from 'dashboard/api/helpCenter/articles';
import { useAlert } from 'dashboard/composables';

const bridge = vi.hoisted(() => ({ store: null, article: null }));
vi.mock('dashboard/api/helpCenter/articles', () => ({
  default: { updateArticle: vi.fn() },
}));
vi.mock('dashboard/helper/uploadHelper', () => ({
  uploadExternalImage: vi.fn(),
  uploadFile: vi.fn(),
}));
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { articleSlug: '7', portalSlug: 'synthetic' } }),
  useRouter: () => ({ push: vi.fn() }),
}));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => bridge.store,
  useMapGetter: name =>
    name === 'articles/articleById' ? bridge.article : { value: () => ({}) },
}));
vi.mock('dashboard/components/widgets/WootWriter/FullEditor.vue', () => ({
  default: {
    props: ['modelValue'],
    emits: ['update:modelValue'],
    template:
      '<textarea class="body" :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
  },
}));
vi.mock('dashboard/components-next/textarea/TextArea.vue', () => ({
  default: {
    props: ['modelValue'],
    emits: ['update:modelValue'],
    template:
      '<textarea class="title" :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
  },
}));
vi.mock('dashboard/components-next/HelpCenter/HelpCenterLayout.vue', () => ({
  default: { template: '<main><slot name="content" /></main>' },
}));
vi.mock(
  'dashboard/components-next/HelpCenter/Pages/ArticleEditorPage/ArticleEditorControls.vue',
  () => ({ default: { template: '<div />' } })
);
vi.mock(
  'dashboard/components-next/HelpCenter/Pages/ArticleEditorPage/ArticleEditorHeader.vue',
  () => ({ default: { template: '<div />' } })
);
vi.mock(
  'dashboard/components-next/HelpCenter/Pages/ArticleEditorPage/ArticleDiffPanel.vue',
  () => ({ default: { template: '<div />' } })
);

let wrapper;
let state;
let serverRecord;
let pending;

beforeEach(() => {
  vi.useFakeTimers();
  state = reactive({
    articles: {
      byId: {
        7: {
          id: 7,
          title: 'Live',
          content: 'Live body',
          draftTitle: 'Draft',
          draftContent: 'Initial',
          status: 'published',
        },
      },
      uiFlags: { byId: {} },
    },
  });
  bridge.article = computed(() => () => state.articles.byId[7]);
  bridge.store = {
    dispatch: (name, payload) =>
      name === 'articles/update'
        ? actions.update(
            { commit: (type, value) => mutations[type](state, value) },
            payload
          )
        : Promise.resolve(),
  };
  serverRecord = {
    id: 7,
    title: 'Live',
    content: 'Live body',
    draft_title: 'Draft',
    draft_content: 'Initial',
    status: 'published',
  };
  pending = [];
  // Model write application at completion, not merely response delivery order.
  articlesAPI.updateArticle.mockImplementation(
    ({ articleObj }) =>
      new Promise((resolve, reject) => {
        pending.push({
          resolve: () => {
            Object.assign(serverRecord, articleObj);
            resolve({ data: { payload: { ...serverRecord } } });
          },
          reject,
        });
      })
  );
  wrapper = mount(Page);
});

afterEach(() => {
  wrapper.unmount();
  vi.useRealTimers();
});

it('serializes overlapping complete snapshots and retains B after remount', async () => {
  await wrapper.get('textarea.body').setValue('A');
  await vi.advanceTimersByTimeAsync(500);
  await wrapper.get('textarea.title').setValue('Title B');
  await wrapper.get('textarea.body').setValue('B');
  await vi.advanceTimersByTimeAsync(500);
  expect(pending).toHaveLength(1);
  pending[0].resolve();
  await flushPromises();
  expect(pending).toHaveLength(2);
  expect(wrapper.findComponent(ArticleEditor).props()).toMatchObject({
    isUpdating: true,
    isSaved: false,
  });
  expect(articlesAPI.updateArticle.mock.calls[1][0].articleObj).toMatchObject({
    draft_title: 'Title B',
    draft_content: 'B',
  });
  pending[1].resolve();
  await flushPromises();
  expect(serverRecord).toMatchObject({
    draft_title: 'Title B',
    draft_content: 'B',
    title: 'Live',
    content: 'Live body',
  });
  expect(state.articles.byId[7].draftContent).toBe('B');
  expect(wrapper.get('textarea.body').element.value).toBe('B');
  expect(wrapper.findComponent(ArticleEditor).props()).toMatchObject({
    isUpdating: false,
    isSaved: true,
  });
  wrapper.unmount();
  wrapper = mount(Page);
  expect(wrapper.get('textarea.body').element.value).toBe('B');
});

it('coalesces text snapshots without losing metadata or empty strings', async () => {
  await wrapper.get('textarea.body').setValue('A');
  await vi.advanceTimersByTimeAsync(500);
  wrapper
    .findComponent(ArticleEditorControls)
    .vm.$emit('saveArticle', { author_id: 12 });
  await wrapper.get('textarea.body').setValue('B');
  await vi.advanceTimersByTimeAsync(500);
  await wrapper.get('textarea.title').setValue('');
  await wrapper.get('textarea.body').setValue('');
  await vi.advanceTimersByTimeAsync(500);
  expect(pending).toHaveLength(1);
  pending[0].resolve();
  await flushPromises();
  expect(articlesAPI.updateArticle.mock.calls[1][0].articleObj).toMatchObject({
    author_id: 12,
    draft_title: '',
    draft_content: '',
  });
  pending[1].resolve();
  await flushPromises();
  expect(pending).toHaveLength(2);
});

it('continues after an older failure and recovers from a terminal failure on a new edit', async () => {
  await wrapper.get('textarea.body').setValue('A');
  await vi.advanceTimersByTimeAsync(500);
  await wrapper.get('textarea.body').setValue('B');
  await vi.advanceTimersByTimeAsync(500);
  pending[0].reject(new Error('A failed'));
  await flushPromises();
  expect(pending).toHaveLength(2);
  expect(useAlert).toHaveBeenCalled();
  pending[1].reject(new Error('B failed'));
  await flushPromises();
  expect(wrapper.findComponent(ArticleEditor).props()).toMatchObject({
    isUpdating: false,
    isSaved: false,
  });
  await vi.advanceTimersByTimeAsync(2000);
  expect(wrapper.findComponent(ArticleEditor).props('isSaved')).toBe(false);
  await wrapper.get('textarea.body').setValue('C');
  await vi.advanceTimersByTimeAsync(500);
  pending[2].resolve();
  await flushPromises();
  expect(serverRecord.draft_content).toBe('C');
  expect(wrapper.findComponent(ArticleEditor).props('isSaved')).toBe(true);
});

it('drains an unmount flush behind the in-flight request', async () => {
  await wrapper.get('textarea.body').setValue('A');
  await vi.advanceTimersByTimeAsync(500);
  await wrapper.get('textarea.body').setValue('B');
  wrapper.unmount();
  expect(pending).toHaveLength(1);
  pending[0].resolve();
  await flushPromises();
  expect(pending).toHaveLength(2);
  pending[1].resolve();
  await flushPromises();
  expect(serverRecord.draft_content).toBe('B');
});

it('does not discard newer typing when an older revert clears the draft', async () => {
  await wrapper.get('textarea.title').setValue('Live');
  await wrapper.get('textarea.body').setValue('Live body');
  await vi.advanceTimersByTimeAsync(500);
  await wrapper.get('textarea.body').setValue('B');
  pending[0].resolve();
  await flushPromises();
  expect(serverRecord.draft_content).toBeNull();
  expect(wrapper.get('textarea.body').element.value).toBe('B');
  await vi.advanceTimersByTimeAsync(500);
  expect(pending).toHaveLength(2);
  pending[1].resolve();
  await flushPromises();
  expect(serverRecord.draft_content).toBe('B');
});

it('preserves ordered saves and sends queued B after A fails', async () => {
  await wrapper.get('textarea.body').setValue('Ordered');
  await vi.advanceTimersByTimeAsync(500);
  pending[0].resolve();
  await flushPromises();
  await wrapper.get('textarea.body').setValue('A');
  await vi.advanceTimersByTimeAsync(500);
  await wrapper.get('textarea.body').setValue('B');
  await vi.advanceTimersByTimeAsync(500);
  pending[1].reject(new Error('Rejected'));
  await flushPromises();
  pending[2].resolve();
  await flushPromises();
  expect(serverRecord.draft_content).toBe('B');
  expect(state.articles.byId[7].draftContent).toBe('B');
  expect(wrapper.findComponent(ArticleEditor).props('isSaved')).toBe(true);
});

it('does not share the drain between mounted page instances', async () => {
  const other = mount(Page);
  try {
    await wrapper.get('textarea.body').setValue('First session');
    await vi.advanceTimersByTimeAsync(500);
    await other.get('textarea.body').setValue('Second session');
    await vi.advanceTimersByTimeAsync(500);
    expect(pending).toHaveLength(2);
    pending[0].resolve();
    pending[1].resolve();
    await flushPromises();
  } finally {
    other.unmount();
  }
});

it('reseeds after an idle draft clear and an article switch', async () => {
  Object.assign(state.articles.byId[7], {
    draftTitle: null,
    draftContent: null,
  });
  await nextTick();
  expect(wrapper.get('textarea.body').element.value).toBe('Live body');
  state.articles.byId[7] = { id: 8, title: 'Other', content: 'Other body' };
  await nextTick();
  expect(wrapper.get('textarea.body').element.value).toBe('Other body');
  expect(pending).toHaveLength(0);
});
