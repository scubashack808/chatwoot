import { flushPromises, shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';
import NextButton from 'dashboard/components-next/button/Button.vue';
import GalleryView from '../GalleryView.vue';

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useImageZoom', () => ({
  useImageZoom: () => ({
    imageWrapperStyle: {},
    imageStyle: {},
    activeImageRotation: 0,
    onRotate: vi.fn(),
    onZoom: vi.fn(),
    onDoubleClickZoomImage: vi.fn(),
    onWheelImageZoom: vi.fn(),
    onMouseMove: vi.fn(),
    onMouseLeave: vi.fn(),
    resetZoomAndRotation: vi.fn(),
  }),
}));

let wrapper;
let attachments;

const mountGallery = async (attachment, allAttachments) => {
  const store = createStore({
    getters: { getCurrentUser: () => ({ id: 7 }) },
  });
  wrapper = shallowMount(GalleryView, {
    props: { show: true, attachment, allAttachments },
    global: {
      plugins: [store],
      directives: { 'dompurify-html': {} },
      stubs: {
        NextButton: false,
        TeleportWithDirection: { template: '<div><slot /></div>' },
      },
    },
  });
  await flushPromises();
};

const navButton = side =>
  wrapper
    .findAllComponents(NextButton)
    .find(button =>
      button.props('icon').startsWith(`ltr:i-lucide-chevron-${side}`)
    );

beforeEach(() => {
  window.cw_keyboard_layout = 'QWERTY';
  attachments = [1, 2, 3].map(id => ({
    id,
    message_id: 10,
    file_type: 'image',
    data_url: `https://media.example.test/${id}.png`,
    sender: { id: 8, name: 'Elena' },
  }));
});

afterEach(() => {
  wrapper?.unmount();
  delete window.cw_keyboard_layout;
});

describe('GalleryView', () => {
  it('opens at the clicked attachment position when a message has several attachments', async () => {
    await mountGallery(attachments[2], attachments);

    expect(wrapper.find('img').attributes('src')).toBe(attachments[2].data_url);
    expect(wrapper.find('footer').text()).toBe('3 / 3');
    expect(navButton('left').attributes('disabled')).toBeUndefined();
    expect(navButton('right').attributes('disabled')).toBeDefined();
  });

  it('navigates to the previous sibling attachment on ArrowLeft', async () => {
    await mountGallery(attachments[2], attachments);

    document.dispatchEvent(
      new KeyboardEvent('keydown', {
        key: 'ArrowLeft',
        code: 'ArrowLeft',
        bubbles: true,
      })
    );
    await flushPromises();

    expect(wrapper.find('img').attributes('src')).toBe(attachments[1].data_url);
    expect(wrapper.find('footer').text()).toBe('2 / 3');
  });

  it('navigates to the previous sibling attachment using the previous button', async () => {
    await mountGallery(attachments[2], attachments);

    await navButton('left').trigger('click');

    expect(wrapper.find('img').attributes('src')).toBe(attachments[1].data_url);
    expect(wrapper.find('footer').text()).toBe('2 / 3');
  });

  it('opens at the first position when the first attachment is clicked', async () => {
    await mountGallery(attachments[0], attachments);

    expect(wrapper.find('img').attributes('src')).toBe(attachments[0].data_url);
    expect(wrapper.find('footer').text()).toBe('1 / 3');
    expect(navButton('left').attributes('disabled')).toBeDefined();
    expect(navButton('right').attributes('disabled')).toBeUndefined();
  });

  it('opens at the clicked position when every attachment has its own message', async () => {
    attachments = attachments.map(attachment => ({
      ...attachment,
      message_id: attachment.id,
    }));
    await mountGallery(attachments[2], attachments);

    expect(wrapper.find('footer').text()).toBe('3 / 3');

    document.dispatchEvent(
      new KeyboardEvent('keydown', {
        key: 'ArrowLeft',
        code: 'ArrowLeft',
        bubbles: true,
      })
    );
    await flushPromises();

    expect(wrapper.find('img').attributes('src')).toBe(attachments[1].data_url);
    expect(wrapper.find('footer').text()).toBe('2 / 3');
  });

  it('falls back to the first position when the attachment is not in the list', async () => {
    await mountGallery(
      {
        ...attachments[0],
        id: 99,
        message_id: 77,
        data_url: 'https://media.example.test/99.png',
      },
      attachments
    );

    expect(wrapper.find('footer').text()).toBe('1 / 3');
  });
});
