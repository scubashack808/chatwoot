import { mount } from '@vue/test-utils';
import { defineComponent, inject, nextTick } from 'vue';
import ResizableEditorWrapper from '../ResizableEditorWrapper.vue';

const getStyleValue = (wrapper, property) =>
  wrapper
    .get('.resizable-editor-wrapper')
    .element.style.getPropertyValue(property);

const mountWrapper = ({ props = {}, slots = {} } = {}) =>
  mount(ResizableEditorWrapper, {
    props: { containerHeight: 600, ...props },
    slots,
  });

describe('ResizableEditorWrapper', () => {
  it('preserves the upstream height defaults when no values are supplied', () => {
    const wrapper = mountWrapper();

    expect(getStyleValue(wrapper, '--editor-height')).toBe('120px');
    expect(getStyleValue(wrapper, '--editor-min-allowed')).toBe('80px');
  });

  it('uses caller-supplied default and minimum heights', () => {
    const wrapper = mountWrapper({
      props: { defaultHeight: 64, minHeight: 64 },
    });

    expect(getStyleValue(wrapper, '--editor-height')).toBe('64px');
    expect(getStyleValue(wrapper, '--editor-min-allowed')).toBe('64px');
  });

  it('resets when a caller changes the height contract', async () => {
    const wrapper = mountWrapper();

    await wrapper.setProps({ defaultHeight: 72, minHeight: 72 });

    expect(getStyleValue(wrapper, '--editor-height')).toBe('72px');
    expect(getStyleValue(wrapper, '--editor-min-allowed')).toBe('72px');
  });

  it('clamps manual resizing to the caller-supplied minimum', async () => {
    const wrapper = mountWrapper({
      props: { defaultHeight: 80, minHeight: 64 },
    });

    await wrapper
      .get('.cursor-row-resize')
      .trigger('mousedown', { clientY: 100 });
    document.dispatchEvent(new MouseEvent('mousemove', { clientY: 300 }));
    await nextTick();

    expect(getStyleValue(wrapper, '--editor-height')).toBe('64px');

    document.dispatchEvent(new MouseEvent('mouseup'));
  });

  it('preserves content growth and resets to the caller-supplied default', async () => {
    const HeightRequester = defineComponent({
      setup() {
        return { requestEditorHeight: inject('requestEditorHeight') };
      },
      template: '<button @click="requestEditorHeight(240)"></button>',
    });
    const wrapper = mountWrapper({
      props: { defaultHeight: 80, minHeight: 64 },
      slots: { default: HeightRequester },
    });

    await wrapper.get('button').trigger('click');
    expect(getStyleValue(wrapper, '--editor-height')).toBe('240px');

    wrapper.vm.resetEditorHeight();
    await nextTick();
    expect(getStyleValue(wrapper, '--editor-height')).toBe('80px');
  });
});
