import { LAYOUT_QWERTY } from 'shared/helpers/KeyboardHelpers';

/**
 * Detects the keyboard layout using the modern navigator.keyboard API.
 * @returns {Promise<string>} A promise that resolves to the detected keyboard layout.
 */
async function detect() {
  const map = await navigator.keyboard.getLayoutMap();
  const q = map.get('KeyQ');
  const w = map.get('KeyW');
  const e = map.get('KeyE');
  const r = map.get('KeyR');
  const t = map.get('KeyT');
  const y = map.get('KeyY');

  return [q, w, e, r, t, y].join('').toUpperCase();
}

/**
 * Detects the keyboard layout with navigator.keyboard, caching the result.
 * Browsers without the API cannot report a layout, so they keep the default QWERTY bindings.
 * @returns {Promise<string>} A promise that resolves to the detected keyboard layout.
 */
export async function useDetectKeyboardLayout() {
  const cachedLayout = window.cw_keyboard_layout;
  if (cachedLayout) {
    return cachedLayout;
  }

  const layout = navigator.keyboard ? await detect() : LAYOUT_QWERTY;
  window.cw_keyboard_layout = layout;
  return layout;
}
