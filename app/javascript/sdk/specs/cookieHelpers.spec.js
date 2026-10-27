import Cookies from 'js-cookie';
import md5 from 'md5';
import {
  computeHashForUserData,
  getUserCookieName,
  getUserString,
  hasUserKeys,
  setCookieWithDomain,
} from '../cookieHelpers';

describe('#getUserCookieName', () => {
  it('returns correct cookie name', () => {
    global.$chatwoot = { websiteToken: '123456' };
    expect(getUserCookieName()).toBe('cw_user_123456');
  });
});

describe('#getUserString', () => {
  it('returns correct user string', () => {
    expect(
      getUserString({
        user: {
          name: 'Pranav',
          email: 'pranav@example.com',
          avatar_url: 'https://images.chatwoot.com/placeholder',
          identifier_hash: '12345',
        },
        identifier: '12345',
      })
    ).toBe(
      'avatar_urlhttps://images.chatwoot.com/placeholderemailpranav@example.comnamePranavidentifier_hash12345identifier12345'
    );

    expect(
      getUserString({
        user: {
          email: 'pranav@example.com',
          avatar_url: 'https://images.chatwoot.com/placeholder',
        },
      })
    ).toBe(
      'avatar_urlhttps://images.chatwoot.com/placeholderemailpranav@example.comnameidentifier_hashidentifier'
    );
  });
});

describe('#computeHashForUserData', () => {
  const profile = { identifier: 'visitor-1', user: { name: 'Visitor' } };

  it.each([undefined, null, {}])(
    'preserves the legacy hash for absent or empty attributes: %j',
    customAttributes => {
      expect(
        computeHashForUserData({
          ...profile,
          user: { ...profile.user, custom_attributes: customAttributes },
        })
      ).toBe(md5(getUserString(profile)));
    }
  );

  it.each([
    [{}, { plan: 'enterprise' }],
    [{ plan: 'starter' }, { plan: 'enterprise' }],
    [{ plan: 'starter' }, { plan: 'starter', seats: 2 }],
    [{ plan: 'starter', seats: 2 }, { seats: 2 }],
    [{ active: true }, { active: false }],
    [{ seats: 1 }, { seats: 0 }],
    [{ note: 'hello' }, { note: '' }],
    [{ note: 'hello' }, { note: null }],
    [{}, { note: null }],
    [{ seats: 1 }, { seats: '1' }],
    [{ tags: ['a', 'b'] }, { tags: ['b', 'a'] }],
    [{ nested: { seats: 1 } }, { nested: { seats: 2 } }],
    [{ nested: { seats: 1 } }, { nested: [{ seats: 1 }] }],
    [{ tags: [{ seats: 1 }] }, { tags: [{ seats: 2 }] }],
    [
      { renews_on: new Date('2026-01-01T00:00:00Z') },
      { renews_on: new Date('2027-01-01T00:00:00Z') },
    ],
  ])('distinguishes custom attribute payloads %j and %j', (before, after) => {
    expect(
      computeHashForUserData({
        ...profile,
        user: { ...profile.user, custom_attributes: before },
      })
    ).not.toBe(
      computeHashForUserData({
        ...profile,
        user: { ...profile.user, custom_attributes: after },
      })
    );
  });

  it('normalizes nested object keys without mutating input or reordering arrays', () => {
    const attributes = {
      z: [{ b: 2, a: 1 }, 'last'],
      a: { y: false, x: null },
    };
    const original = JSON.stringify(attributes);
    expect(
      computeHashForUserData({
        ...profile,
        user: { ...profile.user, custom_attributes: attributes },
      })
    ).toBe(
      computeHashForUserData({
        ...profile,
        user: {
          ...profile.user,
          custom_attributes: {
            a: { x: null, y: false },
            z: [{ a: 1, b: 2 }, 'last'],
          },
        },
      })
    );
    expect(JSON.stringify(attributes)).toBe(original);
  });
});

describe('#hasUserKeys', () => {
  it('checks whether the allowed list of keys are present', () => {
    expect(hasUserKeys({})).toBe(false);
    expect(hasUserKeys({ randomKey: 'randomValue' })).toBe(false);
    expect(hasUserKeys({ avatar_url: 'randomValue' })).toBe(true);
  });
});

// Mock the 'set' method of the 'Cookies' object

describe('setCookieWithDomain', () => {
  beforeEach(() => {
    vi.spyOn(Cookies, 'set');
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('should set a cookie with default parameters', () => {
    setCookieWithDomain('myCookie', 'cookieValue');

    expect(Cookies.set).toHaveBeenCalledWith('myCookie', 'cookieValue', {
      expires: 365,
      sameSite: 'Lax',
      domain: undefined,
    });
  });

  it('should set a cookie with custom expiration and sameSite attribute', () => {
    setCookieWithDomain('myCookie', 'cookieValue', {
      expires: 30,
    });

    expect(Cookies.set).toHaveBeenCalledWith('myCookie', 'cookieValue', {
      expires: 30,
      sameSite: 'Lax',
      domain: undefined,
    });
  });

  it('should set a cookie with a specific base domain', () => {
    setCookieWithDomain('myCookie', 'cookieValue', {
      baseDomain: 'example.com',
    });

    expect(Cookies.set).toHaveBeenCalledWith('myCookie', 'cookieValue', {
      expires: 365,
      sameSite: 'Lax',
      domain: 'example.com',
    });
  });

  it('should stringify the cookie value when setting the value', () => {
    setCookieWithDomain(
      'myCookie',
      { value: 'cookieValue' },
      {
        baseDomain: 'example.com',
      }
    );

    expect(Cookies.set).toHaveBeenCalledWith(
      'myCookie',
      JSON.stringify({ value: 'cookieValue' }),
      {
        expires: 365,
        sameSite: 'Lax',
        domain: 'example.com',
      }
    );
  });

  it('should set a cookie with custom expiration, sameSite attribute, and specific base domain', () => {
    setCookieWithDomain('myCookie', 'cookieValue', {
      expires: 7,
      baseDomain: 'example.com',
    });

    expect(Cookies.set).toHaveBeenCalledWith('myCookie', 'cookieValue', {
      expires: 7,
      sameSite: 'Lax',
      domain: 'example.com',
    });
  });
});
