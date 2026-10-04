import md5 from 'md5';
import Cookies from 'js-cookie';

const REQUIRED_USER_KEYS = ['avatar_url', 'email', 'name'];
const ALLOWED_USER_ATTRIBUTES = [...REQUIRED_USER_KEYS, 'identifier_hash'];

export const getUserCookieName = () => {
  const SET_USER_COOKIE_PREFIX = 'cw_user_';
  const { websiteToken: websiteIdentifier } = window.$chatwoot;
  return `${SET_USER_COOKIE_PREFIX}${websiteIdentifier}`;
};

export const getUserString = ({ identifier = '', user }) => {
  const userStringWithSortedKeys = ALLOWED_USER_ATTRIBUTES.reduce(
    (acc, key) => `${acc}${key}${user[key] || ''}`,
    ''
  );
  return `${userStringWithSortedKeys}identifier${identifier}`;
};

const sortCustomAttributes = value => {
  if (Array.isArray(value)) return value.map(sortCustomAttributes);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map(key => [key, sortCustomAttributes(value[key])])
    );
  }
  return value;
};

export const computeHashForUserData = ({ identifier, user }) => {
  const profileString = getUserString({ identifier, user });
  const customAttributes = user.custom_attributes;
  // Preserve existing cookies when no custom attributes are supplied.
  if (!customAttributes || !Object.keys(customAttributes).length) {
    return md5(profileString);
  }
  // Fingerprint the JSON payload the iframe receives, so Date and other
  // toJSON values compare by their transmitted form.
  const wireAttributes = JSON.parse(JSON.stringify(customAttributes));
  return md5(
    JSON.stringify([profileString, sortCustomAttributes(wireAttributes)])
  );
};

export const hasUserKeys = user =>
  REQUIRED_USER_KEYS.reduce((acc, key) => acc || !!user[key], false);

export const setCookieWithDomain = (
  name,
  value,
  { expires = 365, baseDomain = undefined } = {}
) => {
  const cookieOptions = {
    expires,
    sameSite: 'Lax',
    domain: baseDomain,
  };

  // if type of value is object, stringify it
  // this is because js-cookies 3.0 removed builtin json support
  // ref: https://github.com/js-cookie/js-cookie/releases/tag/v3.0.0
  if (typeof value === 'object') {
    value = JSON.stringify(value);
  }

  Cookies.set(name, value, cookieOptions);
};
