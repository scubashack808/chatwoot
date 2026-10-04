import { IFrameHelper } from '../IFrameHelper';
import { buildPopoutURL } from 'widget/helpers/urlParamsHelper';
import '../../entrypoints/sdk';

vi.mock('js-cookie', () => ({
  default: { get: vi.fn(), set: vi.fn(), remove: vi.fn() },
}));
vi.mock('../IFrameHelper', () => ({
  IFrameHelper: {
    createFrame: vi.fn(),
    sendMessage: vi.fn(),
    getAppFrame: vi.fn(() => ({})),
    getUrl: vi.fn(() => 'https://chat.example.test/widget'),
    events: { popoutChatWindow: vi.fn(), toggleBubble: vi.fn() },
  },
}));

describe('SDK locale', () => {
  const run = locale => {
    window.chatwootSettings = { locale };
    window.chatwootSDK.run({
      baseUrl: 'https://chat.example.test',
      websiteToken: 'synthetic-site',
    });
  };

  const popoutLocale = () => {
    window.$chatwoot.popoutChatWindow();
    const { baseUrl, websiteToken, locale } =
      IFrameHelper.events.popoutChatWindow.mock.lastCall[0];
    const url = buildPopoutURL({
      origin: baseUrl,
      websiteToken,
      locale,
      conversationCookie: 'synthetic',
    });
    return new URL(url).searchParams.get('locale');
  };

  beforeEach(() => {
    vi.clearAllMocks();
    delete window.$chatwoot;
    vi.spyOn(document, 'addEventListener').mockImplementation(() => {});
  });

  afterEach(() => {
    delete window.$chatwoot;
    delete window.chatwootSettings;
    vi.restoreAllMocks();
  });

  it('uses the initial locale in the popout URL', () => {
    run('es');

    expect(popoutLocale()).toBe('es');
  });

  it('uses the locale set with setLocale in the popout URL', () => {
    run('en');
    window.$chatwoot.setLocale('es');

    expect(IFrameHelper.sendMessage).toHaveBeenCalledWith('set-locale', {
      locale: 'es',
    });
    expect(popoutLocale()).toBe('es');
  });

  it('uses the latest locale after repeated changes', () => {
    run('es');
    window.$chatwoot.setLocale('fr');

    expect(popoutLocale()).toBe('fr');
  });

  it('keeps the selected locale for the widget reload after reset', () => {
    run('en');
    window.$chatwoot.setLocale('es');
    window.$chatwoot.reset();

    expect(window.$chatwoot.locale).toBe('es');
  });
});
