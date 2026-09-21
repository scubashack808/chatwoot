// Recipient rules for an email reply.
//
// Upstream's getRecipients builds the reply's To/Cc from the last email and excludes exactly two
// of our addresses, the inbox primary and its forward-to, with a case-sensitive comparison. An
// inbox with aliases therefore copies its own alias into Cc, and the reply is delivered straight
// back into this inbox as new inbound mail. These helpers close that over every address the
// channel owns, case-insensitively, and are used both by the automatic population and by the
// Reply all action so the two cannot drift apart.

export const normalizeAddress = value =>
  typeof value === 'string' ? value.trim().toLowerCase() : '';

export const channelOwnedAddresses = inbox =>
  [inbox?.email, inbox?.forward_to_email, ...(inbox?.aliases || [])]
    .map(normalizeAddress)
    .filter(Boolean);

// Mirrors the server's normalize_email_with_plus_addressing, so "nonprofit+donation@x.com" and
// "NonProfit@x.com" both resolve to the configured "nonprofit@x.com".
export const baseAddress = value => {
  const normalized = normalizeAddress(value);
  if (!normalized.includes('@')) return '';
  const [local, domain] = normalized.split('@');
  return `${local.split('+')[0]}@${domain}`;
};

export const splitAddressList = value =>
  (value || '')
    .split(',')
    .map(address => address.trim())
    .filter(Boolean);

export const rejectOwnedAddresses = (addresses = [], owned = []) => {
  const ownedSet = new Set(owned.map(normalizeAddress));
  const seen = new Set();

  return addresses.filter(address => {
    const key = normalizeAddress(address);
    if (!key || ownedSet.has(key) || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
};

export const sanitizeRecipients = ({ to, cc, bcc } = {}, owned = []) => ({
  to: rejectOwnedAddresses(to || [], owned),
  cc: rejectOwnedAddresses(cc || [], owned),
  bcc: rejectOwnedAddresses(bcc || [], owned),
});

// Which of our addresses the customer most recently wrote to, read from the newest incoming
// message that carries an envelope. This mirrors Email::InboundRecipientFinder so the picker
// SHOWS the address the server will actually send from. The server stays authoritative: the
// composer only sends from_email when the agent picks something other than this.
export const defaultFromAddress = (messages = [], options = []) => {
  const envelope = [...messages]
    .reverse()
    .filter(message => message?.message_type === 0 && !message?.private)
    .map(message => message?.content_attributes?.email)
    .find(Boolean);
  if (!envelope) return '';

  const candidates = [
    ...(envelope.to || []),
    ...(envelope.cc || []),
    ...(envelope.bcc || []),
    envelope.headers?.['x-original-to'],
  ].filter(Boolean);

  const match = candidates
    .map(candidate =>
      options.find(option => baseAddress(option) === baseAddress(candidate))
    )
    .find(Boolean);

  return match || '';
};

// Reply all: everyone the last email reached, minus the people already in To, minus its sender
// (who is in To), minus anything of ours. Whatever the agent already typed into Cc is kept.
export const replyAllCcAddresses = ({
  lastEmail,
  currentTo = '',
  currentCc = '',
  owned = [],
}) => {
  const typedCc = splitAddressList(currentCc);
  const email = lastEmail?.content_attributes?.email;
  if (!email) return rejectOwnedAddresses(typedCc, owned);

  const alreadyAddressed = new Set(
    [...splitAddressList(currentTo), ...(email.from || [])].map(
      normalizeAddress
    )
  );
  const originalRecipients = [...(email.to || []), ...(email.cc || [])].filter(
    address => !alreadyAddressed.has(normalizeAddress(address))
  );

  return rejectOwnedAddresses([...typedCc, ...originalRecipients], owned);
};
