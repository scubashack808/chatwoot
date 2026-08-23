import {
  channelOwnedAddresses,
  baseAddress,
  splitAddressList,
  rejectOwnedAddresses,
  sanitizeRecipients,
  defaultFromAddress,
  replyAllCcAddresses,
} from '../emailRecipientHelper';

// Row 09 behaviour A06: primary, aliases, sender and duplicates never leak into To or Cc.
describe('emailRecipientHelper', () => {
  const inbox = {
    email: 'care@example.com',
    forward_to_email: 'forward-1@chatwoot.com',
    aliases: ['nonprofit@example.com', 'INFO@example.com'],
  };

  describe('channelOwnedAddresses', () => {
    it('collects the primary, the forward-to and every alias, lowercased', () => {
      expect(channelOwnedAddresses(inbox)).toEqual([
        'care@example.com',
        'forward-1@chatwoot.com',
        'nonprofit@example.com',
        'info@example.com',
      ]);
    });

    it('survives an inbox with no aliases and no forward-to', () => {
      expect(channelOwnedAddresses({ email: 'care@example.com' })).toEqual([
        'care@example.com',
      ]);
    });

    it('survives a missing inbox', () => {
      expect(channelOwnedAddresses(undefined)).toEqual([]);
    });
  });

  describe('splitAddressList', () => {
    it('splits, trims and drops blanks', () => {
      expect(splitAddressList(' a@x.com , b@x.com,, ')).toEqual([
        'a@x.com',
        'b@x.com',
      ]);
    });

    it('returns an empty list for an empty value', () => {
      expect(splitAddressList('')).toEqual([]);
      expect(splitAddressList(undefined)).toEqual([]);
    });
  });

  describe('rejectOwnedAddresses', () => {
    const owned = channelOwnedAddresses(inbox);

    it('removes the primary', () => {
      expect(
        rejectOwnedAddresses(['care@example.com', 'a@x.com'], owned)
      ).toEqual(['a@x.com']);
    });

    it('removes an alias regardless of case', () => {
      expect(
        rejectOwnedAddresses(['NonProfit@Example.com', 'a@x.com'], owned)
      ).toEqual(['a@x.com']);
    });

    it('removes the forward-to address', () => {
      expect(
        rejectOwnedAddresses(['forward-1@chatwoot.com', 'a@x.com'], owned)
      ).toEqual(['a@x.com']);
    });

    it('de-duplicates case-insensitively and keeps the first spelling', () => {
      expect(
        rejectOwnedAddresses(['A@x.com', 'a@x.com', 'b@x.com'], owned)
      ).toEqual(['A@x.com', 'b@x.com']);
    });

    it('keeps addresses that are not ours', () => {
      expect(rejectOwnedAddresses(['a@x.com', 'b@x.com'], owned)).toEqual([
        'a@x.com',
        'b@x.com',
      ]);
    });
  });

  describe('sanitizeRecipients', () => {
    it('strips our own addresses out of to, cc and bcc at once', () => {
      const result = sanitizeRecipients(
        {
          to: ['customer@example.com', 'nonprofit@example.com'],
          cc: ['info@example.com', 'colleague@example.com'],
          bcc: ['care@example.com'],
        },
        channelOwnedAddresses(inbox)
      );

      expect(result).toEqual({
        to: ['customer@example.com'],
        cc: ['colleague@example.com'],
        bcc: [],
      });
    });

    it('tolerates missing lists', () => {
      expect(sanitizeRecipients({}, channelOwnedAddresses(inbox))).toEqual({
        to: [],
        cc: [],
        bcc: [],
      });
    });
  });

  describe('baseAddress', () => {
    it('lowercases and strips a plus extension', () => {
      expect(baseAddress(' NonProfit+Donation@Example.com ')).toBe(
        'nonprofit@example.com'
      );
    });

    it('returns an empty string for a non-address', () => {
      expect(baseAddress('not-an-address')).toBe('');
      expect(baseAddress(undefined)).toBe('');
    });
  });

  // Mirrors Email::InboundRecipientFinder so the picker shows what the server will do.
  describe('defaultFromAddress', () => {
    const options = ['care@example.com', 'nonprofit@example.com'];
    const inbound = to => ({
      message_type: 0,
      content_attributes: { email: { to, cc: [], bcc: [] } },
    });

    it('returns the alias the newest inbound message arrived at', () => {
      expect(
        defaultFromAddress(
          [inbound(['care@example.com']), inbound(['nonprofit@example.com'])],
          options
        )
      ).toBe('nonprofit@example.com');
    });

    it('ignores outgoing messages', () => {
      const outgoing = {
        message_type: 1,
        content_attributes: { email: { to: ['care@example.com'] } },
      };
      expect(
        defaultFromAddress(
          [inbound(['nonprofit@example.com']), outgoing],
          options
        )
      ).toBe('nonprofit@example.com');
    });

    it('matches a plus-addressed or case-different recipient', () => {
      expect(
        defaultFromAddress([inbound(['NonProfit+x@Example.com'])], options)
      ).toBe('nonprofit@example.com');
    });

    it('reads the stored X-Original-To when the visible To is not ours', () => {
      const message = {
        message_type: 0,
        content_attributes: {
          email: {
            to: ['someone@example.com'],
            headers: { 'x-original-to': 'nonprofit@example.com' },
          },
        },
      };
      expect(defaultFromAddress([message], options)).toBe(
        'nonprofit@example.com'
      );
    });

    it('returns an empty string when nothing addressed to us is known', () => {
      expect(
        defaultFromAddress([inbound(['stranger@example.com'])], options)
      ).toBe('');
      expect(defaultFromAddress([], options)).toBe('');
    });
  });

  describe('replyAllCcAddresses', () => {
    const lastEmail = {
      content_attributes: {
        email: {
          from: ['customer@example.com'],
          to: ['nonprofit@example.com', 'colleague@example.com'],
          cc: ['INFO@example.com', 'partner@example.com'],
        },
      },
    };

    it('adds the other original recipients and never one of our own addresses', () => {
      expect(
        replyAllCcAddresses({
          lastEmail,
          currentTo: 'customer@example.com',
          currentCc: '',
          owned: channelOwnedAddresses(inbox),
        })
      ).toEqual(['colleague@example.com', 'partner@example.com']);
    });

    it('never copies the sender, who is already in To', () => {
      expect(
        replyAllCcAddresses({
          lastEmail,
          currentTo: 'customer@example.com',
          currentCc: '',
          owned: channelOwnedAddresses(inbox),
        })
      ).not.toContain('customer@example.com');
    });

    it('preserves what the agent already typed into Cc and de-duplicates', () => {
      expect(
        replyAllCcAddresses({
          lastEmail,
          currentTo: 'customer@example.com',
          currentCc: 'typed@example.com, Colleague@example.com',
          owned: channelOwnedAddresses(inbox),
        })
      ).toEqual([
        'typed@example.com',
        'Colleague@example.com',
        'partner@example.com',
      ]);
    });

    it('returns the current cc unchanged when there is no last email', () => {
      expect(
        replyAllCcAddresses({
          lastEmail: null,
          currentTo: '',
          currentCc: 'typed@example.com',
          owned: channelOwnedAddresses(inbox),
        })
      ).toEqual(['typed@example.com']);
    });
  });
});
