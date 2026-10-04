import {
  extractPlainTextFromHtml,
  getEmailSenderName,
  getEmailSenderEmail,
  getEmailDate,
  formatQuotedEmailDate,
  getInboxEmail,
  buildQuotedEmailHeader,
  buildQuotedEmailHeaderFromContact,
  buildQuotedEmailHeaderFromInbox,
  formatQuotedTextAsBlockquote,
  extractQuotedEmailText,
  truncatePreviewText,
  appendQuotedTextToMessage,
} from '../quotedEmailHelper';
import { buildCreatePayload } from 'dashboard/api/inbox/message';
import { PRODUCTION_LEGACY_QUOTE_CSS_HTML } from './fixtures/legacyQuoteCssFixtures';

describe('quotedEmailHelper', () => {
  describe('extractPlainTextFromHtml', () => {
    it('returns empty string for null or undefined', () => {
      expect(extractPlainTextFromHtml(null)).toBe('');
      expect(extractPlainTextFromHtml(undefined)).toBe('');
    });

    it('strips HTML tags and returns plain text', () => {
      const html = '<p>Hello <strong>world</strong></p>';
      const result = extractPlainTextFromHtml(html);
      expect(result).toBe('Hello world');
    });

    it.each([
      ['<div><p>First</p><p>Second</p></div>', 'First\nSecond'],
      ['Before<div>Middle</div>After', 'Before\nMiddle\nAfter'],
      ['<div><div>Only</div></div>', 'Only'],
      ['<p>First<br><br>Second</p>', 'First\n\nSecond'],
      ['<br>First<br>', '\nFirst\n'],
      ['<p>First</p><br>Second', 'First\nSecond'],
      ['<p>Certifi<span>cation</span> <a>card</a>.</p>', 'Certification card.'],
      ['<p>  Keep <span> spaces </span> </p>', '  Keep  spaces  '],
      ['<pre>First\n  Second</pre>', 'First\n  Second'],
      ['<pre><b>First</b>\n  <b>Second</b></pre>', 'First\n  Second'],
      ['<div>\n  <p>First</p>\n  <p>Second</p>\n</div>', 'First\nSecond'],
      [
        '<html><body>\n<div>\n  <p>Meet at 7am.</p>\n  <p>Bring ID.</p>\n</div>\n</body></html>',
        'Meet at 7am.\nBring ID.',
      ],
      ['<div>\r\n<p>First</p>\r\n<p>Second</p>\r\n</div>', 'First\nSecond'],
      ['<p><b>Inline</b> <i>space</i></p>', 'Inline space'],
      ['<table><tr><td>A</td></tr><tr><td>C</td></tr></table>', 'A\nC'],
      ['Top<hr>Bottom', 'Top\nBottom'],
      ['<ul>\n  <li>One</li>\n  <li>Two</li>\n</ul>', 'One\nTwo'],
      ['<style>bad CSS</style><script>bad()</script><p>Visible</p>', 'Visible'],
      ['', ''],
    ])('preserves semantic boundaries and text in %s', (html, expected) => {
      expect(extractPlainTextFromHtml(html)).toBe(expected);
    });

    it.each([
      'p',
      'div',
      'blockquote',
      'li',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'pre',
      'section',
      'article',
      'header',
      'footer',
    ])('separates adjacent %s blocks', tag => {
      expect(
        extractPlainTextFromHtml(
          `<${tag}>First</${tag}><${tag}>Second</${tag}>`
        )
      ).toBe('First\nSecond');
    });

    it('handles complex HTML structure', () => {
      const html = '<div><p>Line 1</p><p>Line 2</p></div>';
      const result = extractPlainTextFromHtml(html);
      expect(result).toContain('Line 1');
      expect(result).toContain('Line 2');
    });

    it('sanitizes onerror handlers from img tags', () => {
      const html = '<p>Hello</p><img src="x" onerror="alert(1)">';
      const result = extractPlainTextFromHtml(html);
      expect(result).toBe('Hello');
    });

    it('sanitizes script tags', () => {
      const html = '<p>Safe</p><script>alert(1)</script><p>Content</p>';
      const result = extractPlainTextFromHtml(html);
      expect(result).toContain('Safe');
      expect(result).toContain('Content');
      expect(result).not.toContain('alert');
    });

    it('sanitizes onclick handlers', () => {
      const html = '<p onclick="alert(1)">Click me</p>';
      const result = extractPlainTextFromHtml(html);
      expect(result).toBe('Click me');
    });
  });

  describe('getEmailSenderName', () => {
    it('returns sender name from lastEmail', () => {
      const lastEmail = { sender: { name: 'John Doe' } };
      const result = getEmailSenderName(lastEmail, {});
      expect(result).toBe('John Doe');
    });

    it('returns contact name if sender name not available', () => {
      const lastEmail = { sender: {} };
      const contact = { name: 'Jane Smith' };
      const result = getEmailSenderName(lastEmail, contact);
      expect(result).toBe('Jane Smith');
    });

    it('returns empty string if neither available', () => {
      const result = getEmailSenderName({}, {});
      expect(result).toBe('');
    });

    it('trims whitespace from names', () => {
      const lastEmail = { sender: { name: '  John Doe  ' } };
      const result = getEmailSenderName(lastEmail, {});
      expect(result).toBe('John Doe');
    });
  });

  describe('getEmailSenderEmail', () => {
    it('returns sender email from lastEmail', () => {
      const lastEmail = { sender: { email: 'john@example.com' } };
      const result = getEmailSenderEmail(lastEmail, {});
      expect(result).toBe('john@example.com');
    });

    it('returns email from contentAttributes if sender email not available', () => {
      const lastEmail = {
        contentAttributes: {
          email: { from: ['jane@example.com'] },
        },
      };
      const result = getEmailSenderEmail(lastEmail, {});
      expect(result).toBe('jane@example.com');
    });

    it('returns contact email as fallback', () => {
      const lastEmail = {};
      const contact = { email: 'contact@example.com' };
      const result = getEmailSenderEmail(lastEmail, contact);
      expect(result).toBe('contact@example.com');
    });

    it('trims whitespace from emails', () => {
      const lastEmail = { sender: { email: '  john@example.com  ' } };
      const result = getEmailSenderEmail(lastEmail, {});
      expect(result).toBe('john@example.com');
    });
  });

  describe('getEmailDate', () => {
    it('returns parsed date from email metadata', () => {
      const lastEmail = {
        contentAttributes: {
          email: { date: '2024-01-15T10:30:00Z' },
        },
      };
      const result = getEmailDate(lastEmail);
      expect(result).toBeInstanceOf(Date);
    });

    it('returns date from created_at timestamp', () => {
      const lastEmail = { created_at: 1705318200 };
      const result = getEmailDate(lastEmail);
      expect(result).toBeInstanceOf(Date);
    });

    it('handles millisecond timestamps', () => {
      const lastEmail = { created_at: 1705318200000 };
      const result = getEmailDate(lastEmail);
      expect(result).toBeInstanceOf(Date);
    });

    it('returns null if no valid date found', () => {
      const result = getEmailDate({});
      expect(result).toBeNull();
    });
  });

  describe('formatQuotedEmailDate', () => {
    it('formats date correctly', () => {
      const date = new Date('2024-01-15T10:30:00Z');
      const result = formatQuotedEmailDate(date);
      expect(result).toMatch(/Mon, Jan 15, 2024 at/);
    });

    it('returns empty string for invalid date', () => {
      const result = formatQuotedEmailDate('invalid');
      expect(result).toBe('');
    });
  });

  describe('getInboxEmail', () => {
    it('returns email from contentAttributes.email.to', () => {
      const lastEmail = {
        contentAttributes: {
          email: { to: ['inbox@example.com'] },
        },
      };
      const result = getInboxEmail(lastEmail, {});
      expect(result).toBe('inbox@example.com');
    });

    it('returns inbox email as fallback', () => {
      const lastEmail = {};
      const inbox = { email: 'support@example.com' };
      const result = getInboxEmail(lastEmail, inbox);
      expect(result).toBe('support@example.com');
    });

    it('returns empty string if no email found', () => {
      expect(getInboxEmail({}, {})).toBe('');
    });

    it('trims whitespace from emails', () => {
      const lastEmail = {
        contentAttributes: {
          email: { to: ['  inbox@example.com  '] },
        },
      };
      const result = getInboxEmail(lastEmail, {});
      expect(result).toBe('inbox@example.com');
    });
  });

  describe('buildQuotedEmailHeaderFromContact', () => {
    it('builds complete header with name and email', () => {
      const lastEmail = {
        sender: { name: 'John Doe', email: 'john@example.com' },
        contentAttributes: {
          email: { date: '2024-01-15T10:30:00Z' },
        },
      };
      const result = buildQuotedEmailHeaderFromContact(lastEmail, {});
      expect(result).toContain('John Doe');
      expect(result).toContain('john@example.com');
      expect(result).toContain('wrote:');
    });

    it('builds header without name if not available', () => {
      const lastEmail = {
        sender: { email: 'john@example.com' },
        contentAttributes: {
          email: { date: '2024-01-15T10:30:00Z' },
        },
      };
      const result = buildQuotedEmailHeaderFromContact(lastEmail, {});
      expect(result).toContain('<john@example.com>');
      expect(result).not.toContain('undefined');
    });

    it('returns empty string if missing required data', () => {
      expect(buildQuotedEmailHeaderFromContact(null, {})).toBe('');
      expect(buildQuotedEmailHeaderFromContact({}, {})).toBe('');
    });
  });

  describe('buildQuotedEmailHeaderFromInbox', () => {
    it('builds complete header with inbox name and email', () => {
      const lastEmail = {
        contentAttributes: {
          email: {
            date: '2024-01-15T10:30:00Z',
            to: ['support@example.com'],
          },
        },
      };
      const inbox = { name: 'Support Team', email: 'support@example.com' };
      const result = buildQuotedEmailHeaderFromInbox(lastEmail, inbox);
      expect(result).toContain('Support Team');
      expect(result).toContain('support@example.com');
      expect(result).toContain('wrote:');
    });

    it('builds header without name if not available', () => {
      const lastEmail = {
        contentAttributes: {
          email: {
            date: '2024-01-15T10:30:00Z',
            to: ['inbox@example.com'],
          },
        },
      };
      const inbox = { email: 'inbox@example.com' };
      const result = buildQuotedEmailHeaderFromInbox(lastEmail, inbox);
      expect(result).toContain('<inbox@example.com>');
      expect(result).not.toContain('undefined');
    });

    it('returns empty string if missing required data', () => {
      expect(buildQuotedEmailHeaderFromInbox(null, {})).toBe('');
      expect(buildQuotedEmailHeaderFromInbox({}, {})).toBe('');
    });
  });

  describe('buildQuotedEmailHeader', () => {
    it('uses inbox email for outgoing messages (message_type: 1)', () => {
      const lastEmail = {
        message_type: 1,
        contentAttributes: {
          email: {
            date: '2024-01-15T10:30:00Z',
            to: ['support@example.com'],
          },
        },
      };
      const inbox = { name: 'Support', email: 'support@example.com' };
      const contact = { name: 'John Doe', email: 'john@example.com' };
      const result = buildQuotedEmailHeader(lastEmail, contact, inbox);
      expect(result).toContain('Support');
      expect(result).toContain('support@example.com');
      expect(result).not.toContain('John Doe');
    });

    it('uses contact email for incoming messages (message_type: 0)', () => {
      const lastEmail = {
        message_type: 0,
        sender: { name: 'Jane Smith', email: 'jane@example.com' },
        contentAttributes: {
          email: { date: '2024-01-15T10:30:00Z' },
        },
      };
      const inbox = { name: 'Support', email: 'support@example.com' };
      const contact = { name: 'Jane Smith', email: 'jane@example.com' };
      const result = buildQuotedEmailHeader(lastEmail, contact, inbox);
      expect(result).toContain('Jane Smith');
      expect(result).toContain('jane@example.com');
      expect(result).not.toContain('Support');
    });

    it('returns empty string if missing required data', () => {
      expect(buildQuotedEmailHeader(null, {}, {})).toBe('');
      expect(buildQuotedEmailHeader({}, {}, {})).toBe('');
    });
  });

  describe('formatQuotedTextAsBlockquote', () => {
    it('formats single line text', () => {
      const result = formatQuotedTextAsBlockquote('Hello world');
      expect(result).toBe('> Hello world');
    });

    it('formats multi-line text', () => {
      const text = 'Line 1\nLine 2\nLine 3';
      const result = formatQuotedTextAsBlockquote(text);
      expect(result).toBe('> Line 1\n> Line 2\n> Line 3');
    });

    it('includes header if provided', () => {
      const result = formatQuotedTextAsBlockquote('Hello', 'Header text');
      expect(result).toContain('> Header text');
      expect(result).toContain('>\n> Hello');
    });

    it('handles empty lines correctly', () => {
      const text = 'Line 1\n\nLine 3';
      const result = formatQuotedTextAsBlockquote(text);
      expect(result).toBe('> Line 1\n>\n> Line 3');
    });

    it('returns empty string for empty input', () => {
      expect(formatQuotedTextAsBlockquote('')).toBe('');
      expect(formatQuotedTextAsBlockquote('', '')).toBe('');
    });

    it('handles Windows line endings', () => {
      const text = 'Line 1\r\nLine 2';
      const result = formatQuotedTextAsBlockquote(text);
      expect(result).toBe('> Line 1\n> Line 2');
    });
  });

  describe('extractQuotedEmailText', () => {
    it.each(['reply', 'full'])(
      'preserves HTML %s boundaries in the outgoing payload',
      field => {
        const lastEmail = {
          message_type: 0,
          content_attributes: {
            email: {
              text_content: {},
              html_content: {
                [field]:
                  '<p>Meet at 7am.</p><p>Bring ID.<br>Bring certification.</p>',
              },
            },
          },
        };
        const text = extractQuotedEmailText(lastEmail);
        const payload = buildCreatePayload({
          message: appendQuotedTextToMessage(
            'Confirmed.',
            text,
            'Guest wrote:'
          ),
        });
        expect.soft(text).toBe('Meet at 7am.\nBring ID.\nBring certification.');
        expect(payload.content).toBe(
          'Confirmed.\n\n> Guest wrote:\n>\n> Meet at 7am.\n> Bring ID.\n> Bring certification.'
        );
      }
    );

    it.each(['reply', 'full'])(
      'prefers plain MIME %s and preserves its newlines',
      field => {
        const lastEmail = {
          content_attributes: {
            email: {
              text_content: { [field]: 'First line\nSecond line' },
              html_content: { reply: '<p>HTML alternative</p>' },
            },
          },
        };
        const text = extractQuotedEmailText(lastEmail);
        expect(text).toBe('First line\nSecond line');
        expect(
          appendQuotedTextToMessage('Reply', text, 'Guest wrote:')
        ).toContain('> First line\n> Second line');
      }
    );

    it('extracts text from textContent.reply', () => {
      const lastEmail = {
        contentAttributes: {
          email: { textContent: { reply: 'Reply text' } },
        },
      };
      const result = extractQuotedEmailText(lastEmail);
      expect(result).toBe('Reply text');
    });

    it('falls back to textContent.full', () => {
      const lastEmail = {
        contentAttributes: {
          email: { textContent: { full: 'Full text' } },
        },
      };
      const result = extractQuotedEmailText(lastEmail);
      expect(result).toBe('Full text');
    });

    it('extracts from htmlContent and converts to plain text', () => {
      const lastEmail = {
        contentAttributes: {
          email: { htmlContent: { reply: '<p>HTML reply</p>' } },
        },
      };
      const result = extractQuotedEmailText(lastEmail);
      expect(result).toBe('HTML reply');
    });

    it('uses fallback content if structured content not available', () => {
      const lastEmail = { content: 'Fallback content' };
      const result = extractQuotedEmailText(lastEmail);
      expect(result).toBe('Fallback content');
    });

    it('returns empty string for null or missing email', () => {
      expect(extractQuotedEmailText(null)).toBe('');
      expect(extractQuotedEmailText({})).toBe('');
    });

    // Historical rows store a quote-hiding style element inside html_content.
    // DOMPurify keeps style elements under its default config, so without a strip
    // the CSS rule text would land in the agent's reply draft. Both cases below
    // reach the html branches only because text_content is absent, which is the
    // precondition for this path.
    it('does not leak the legacy stored CSS from html_content.reply into the draft', () => {
      const lastEmail = {
        content_attributes: {
          email: { html_content: { reply: PRODUCTION_LEGACY_QUOTE_CSS_HTML } },
        },
      };

      const quoted = extractQuotedEmailText(lastEmail);

      expect(quoted).not.toContain('display: none');
      expect(quoted).not.toContain('blockquote {');
      expect(quoted).toContain('cooking with fire');
    });

    it('does not leak the legacy stored CSS from html_content.full into the draft', () => {
      const lastEmail = {
        content_attributes: {
          email: { html_content: { full: PRODUCTION_LEGACY_QUOTE_CSS_HTML } },
        },
      };

      const quoted = extractQuotedEmailText(lastEmail);

      expect(quoted).not.toContain('display: none');
      expect(quoted).not.toContain('blockquote {');
      expect(quoted).toContain('cooking with fire');
    });
  });

  describe('truncatePreviewText', () => {
    it('returns full text if under max length', () => {
      const text = 'Short text';
      const result = truncatePreviewText(text, 80);
      expect(result).toBe('Short text');
    });

    it('truncates text exceeding max length', () => {
      const text = 'A'.repeat(100);
      const result = truncatePreviewText(text, 80);
      expect(result).toHaveLength(80);
      expect(result).toContain('...');
    });

    it('collapses multiple spaces', () => {
      const text = 'Text   with    spaces';
      const result = truncatePreviewText(text);
      expect(result).toBe('Text with spaces');
    });

    it('trims whitespace', () => {
      const text = '  Text with spaces  ';
      const result = truncatePreviewText(text);
      expect(result).toBe('Text with spaces');
    });

    it('returns empty string for empty input', () => {
      expect(truncatePreviewText('')).toBe('');
      expect(truncatePreviewText('   ')).toBe('');
    });

    it('uses default max length of 80', () => {
      const text = 'A'.repeat(100);
      const result = truncatePreviewText(text);
      expect(result).toHaveLength(80);
    });
  });

  describe('appendQuotedTextToMessage', () => {
    it('appends quoted text to message', () => {
      const message = 'My reply';
      const quotedText = 'Original message';
      const header = 'On date sender wrote:';
      const result = appendQuotedTextToMessage(message, quotedText, header);

      expect(result).toContain('My reply');
      expect(result).toContain('> On date sender wrote:');
      expect(result).toContain('> Original message');
    });

    it('returns only quoted text if message is empty', () => {
      const result = appendQuotedTextToMessage('', 'Quoted', 'Header');
      expect(result).toContain('> Header');
      expect(result).toContain('> Quoted');
      expect(result).not.toContain('\n\n\n');
    });

    it('returns message if no quoted text', () => {
      const result = appendQuotedTextToMessage('Message', '', '');
      expect(result).toBe('Message');
    });

    it('handles proper spacing with double newline', () => {
      const result = appendQuotedTextToMessage('Message', 'Quoted', 'Header');
      expect(result).toContain('Message\n\n>');
    });

    it('does not add extra newlines if message already ends with newlines', () => {
      const result = appendQuotedTextToMessage(
        'Message\n\n',
        'Quoted',
        'Header'
      );
      expect(result).not.toContain('\n\n\n');
    });

    it('adds single newline if message ends with one newline', () => {
      const result = appendQuotedTextToMessage('Message\n', 'Quoted', 'Header');
      expect(result).toContain('Message\n\n>');
    });
  });
});
