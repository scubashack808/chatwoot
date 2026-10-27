import Cookies from 'js-cookie';
import { IFrameHelper } from '../IFrameHelper';
import '../../entrypoints/sdk';

const cookieJar = vi.hoisted(() => new Map());
vi.mock('js-cookie', () => ({
  default: {
    get: key => cookieJar.get(key),
    set: (key, value) => cookieJar.set(key, value),
    remove: key => cookieJar.delete(key),
  },
}));
vi.mock('../IFrameHelper', () => ({
  IFrameHelper: { createFrame: vi.fn(), sendMessage: vi.fn() },
}));

describe('SDK setUser deduplication', () => {
  const user = {
    name: 'Visitor',
    email: 'visitor@example.test',
    phone_number: '+18085550101',
  };

  beforeEach(() => {
    cookieJar.clear();
    delete window.$chatwoot;
    window.chatwootSettings = { locale: 'en' };
    vi.spyOn(document, 'addEventListener').mockImplementation(() => {});
    window.chatwootSDK.run({
      baseUrl: 'https://chat.example.test',
      websiteToken: 'synthetic-site',
    });
  });

  afterEach(() => {
    delete window.$chatwoot;
    delete window.chatwootSettings;
    vi.restoreAllMocks();
  });

  it('transmits a custom-attribute-only change and stores its new hash', () => {
    window.$chatwoot.setUser('visitor-1', user);
    const previousHash = Cookies.get('cw_user_synthetic-site');
    const updated = { ...user, custom_attributes: { plan: 'enterprise' } };
    window.$chatwoot.setUser('visitor-1', updated);

    expect(IFrameHelper.sendMessage).toHaveBeenCalledTimes(2);
    expect(IFrameHelper.sendMessage).toHaveBeenLastCalledWith('set-user', {
      identifier: 'visitor-1',
      user: updated,
    });
    expect(Cookies.get('cw_user_synthetic-site')).not.toBe(previousHash);
  });

  it('deduplicates identical input', () => {
    window.$chatwoot.setUser('visitor-1', user);
    window.$chatwoot.setUser('visitor-1', { ...user });
    expect(IFrameHelper.sendMessage).toHaveBeenCalledTimes(1);
  });

  it('transmits a changed name', () => {
    window.$chatwoot.setUser('visitor-1', user);
    window.$chatwoot.setUser('visitor-1', { ...user, name: 'Visitor Updated' });
    expect(IFrameHelper.sendMessage).toHaveBeenCalledTimes(2);
  });

  it('deduplicates equivalent custom attributes regardless of key order', () => {
    window.$chatwoot.setUser('visitor-1', {
      ...user,
      custom_attributes: {
        plan: 'enterprise',
        details: { seats: 2, active: true },
      },
    });
    window.$chatwoot.setUser('visitor-1', {
      ...user,
      custom_attributes: {
        details: { active: true, seats: 2 },
        plan: 'enterprise',
      },
    });
    expect(IFrameHelper.sendMessage).toHaveBeenCalledTimes(1);
  });

  it.each([undefined, {}])(
    'transmits a cleared payload once without synthesizing deletion: %j',
    customAttributes => {
      window.$chatwoot.setUser('visitor-1', {
        ...user,
        custom_attributes: { plan: 'enterprise' },
      });
      const updated = { ...user, custom_attributes: customAttributes };
      window.$chatwoot.setUser('visitor-1', updated);
      window.$chatwoot.setUser('visitor-1', updated);
      expect(IFrameHelper.sendMessage).toHaveBeenCalledTimes(2);
      expect(IFrameHelper.sendMessage).toHaveBeenLastCalledWith('set-user', {
        identifier: 'visitor-1',
        user: updated,
      });
    }
  );

  it('keeps explicit custom attribute deletion separate', () => {
    window.$chatwoot.deleteCustomAttribute('plan');
    expect(IFrameHelper.sendMessage).toHaveBeenCalledExactlyOnceWith(
      'delete-custom-attribute',
      { customAttribute: 'plan' }
    );
  });

  it('still requires a qualifying profile field', () => {
    expect(() =>
      window.$chatwoot.setUser('visitor-1', {
        custom_attributes: { plan: 'enterprise' },
      })
    ).toThrow(
      'User object should have one of the keys [avatar_url, email, name]'
    );
    expect(IFrameHelper.sendMessage).not.toHaveBeenCalled();
  });
});
