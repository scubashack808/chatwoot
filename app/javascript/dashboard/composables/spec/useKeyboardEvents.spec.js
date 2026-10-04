const keyboardEventsMock = vi.hoisted(() => ({
  mountedCallbacks: [],
  unmountedCallbacks: [],
  registeredKeybindings: {},
}));

vi.mock('vue', async importOriginal => ({
  ...(await importOriginal()),
  onMounted: vi.fn(callback =>
    keyboardEventsMock.mountedCallbacks.push(callback)
  ),
  onUnmounted: vi.fn(callback =>
    keyboardEventsMock.unmountedCallbacks.push(callback)
  ),
}));

vi.mock('dashboard/composables/useDetectKeyboardLayout', () => ({
  useDetectKeyboardLayout: vi.fn(() => Promise.resolve('QWERTY')),
}));

vi.mock('tinykeys', () => ({
  createKeybindingsHandler: vi.fn(keybindings => {
    keyboardEventsMock.registeredKeybindings = keybindings;
    return event => keybindings[event.shortcut]?.(event);
  }),
}));

import { useDetectKeyboardLayout } from 'dashboard/composables/useDetectKeyboardLayout';
import { useKeyboardEvents } from 'dashboard/composables/useKeyboardEvents';
import { LAYOUT_QWERTZ } from 'shared/helpers/KeyboardHelpers';

const mount = async events => {
  useKeyboardEvents(events);
  await keyboardEventsMock.mountedCallbacks[0]();
  return keyboardEventsMock.registeredKeybindings;
};

describe('useKeyboardEvents', () => {
  beforeEach(() => {
    keyboardEventsMock.mountedCallbacks = [];
    keyboardEventsMock.unmountedCallbacks = [];
    keyboardEventsMock.registeredKeybindings = {};
  });

  it('should be defined', () => {
    expect(useKeyboardEvents).toBeDefined();
  });

  it('should return a function', () => {
    expect(useKeyboardEvents).toBeInstanceOf(Function);
  });

  it('registers keybindings on mount and removes the listener on unmount', async () => {
    const addEventListener = vi.spyOn(document, 'addEventListener');

    const keybindings = await mount({ 'ALT+KeyL': () => {} });
    expect(Object.keys(keybindings)).toEqual(['ALT+KeyL']);

    const { signal } = addEventListener.mock.calls[0][2];
    expect(signal.aborted).toBe(false);

    keyboardEventsMock.unmountedCallbacks[0]();
    expect(signal.aborted).toBe(true);
  });

  it('prefixes Shift on QWERTZ layouts for the affected keys', async () => {
    useDetectKeyboardLayout.mockResolvedValueOnce(LAYOUT_QWERTZ);

    const keybindings = await mount({ 'Alt+KeyL': () => {} });

    expect(Object.keys(keybindings)).toEqual(['Shift+Alt+KeyL']);
  });

  it('keeps default bindings when the keyboard layout API is unavailable', async () => {
    const actual = await vi.importActual(
      'dashboard/composables/useDetectKeyboardLayout'
    );
    useDetectKeyboardLayout.mockImplementationOnce(
      actual.useDetectKeyboardLayout
    );
    const originalKeyboard = navigator.keyboard;
    navigator.keyboard = undefined;
    window.cw_keyboard_layout = null;

    const keybindings = await mount({
      'Alt+KeyP': () => {},
      'Alt+KeyL': () => {},
    });

    expect(Object.keys(keybindings)).toEqual(['Alt+KeyP', 'Alt+KeyL']);
    navigator.keyboard = originalKeyboard;
    window.cw_keyboard_layout = null;
  });

  it('ignores shortcuts on focused typeable elements by default', async () => {
    const action = vi.fn();
    const keybindings = await mount({
      'Alt+KeyL': { action, allowOnFocusedInput: false },
    });

    keybindings['Alt+KeyL']({ target: document.createElement('textarea') });

    expect(action).not.toHaveBeenCalled();
  });

  it('runs shortcuts on focused typeable elements when allowed', async () => {
    const action = vi.fn();
    const keybindings = await mount({
      'Alt+KeyL': { action, allowOnFocusedInput: true },
    });

    keybindings['Alt+KeyL']({ target: document.createElement('textarea') });

    expect(action).toHaveBeenCalledTimes(1);
  });
});
