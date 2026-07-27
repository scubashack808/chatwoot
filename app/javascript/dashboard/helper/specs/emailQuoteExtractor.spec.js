import { describe, it, expect } from 'vitest';
import { EmailQuoteExtractor } from '../emailQuoteExtractor.js';

const SAMPLE_EMAIL_HTML = `
<p>method</p>
<blockquote>
<p>On Mon, Sep 29, 2025 at 5:18 PM John <a href="mailto:shivam@chatwoot.com">shivam@chatwoot.com</a> wrote:</p>
<p>Hi</p>
<blockquote>
<p>On Mon, Sep 29, 2025 at 5:17 PM Shivam Mishra <a href="mailto:shivam@chatwoot.com">shivam@chatwoot.com</a> wrote:</p>
<p>Yes, it is.</p>
<p>On Mon, Sep 29, 2025 at 5:16 PM John from Shaneforwoot &lt; shaneforwoot@gmail.com&gt; wrote:</p>
<blockquote>
<p>Hey</p>
<p>On Mon, Sep 29, 2025 at 4:59 PM John shivam@chatwoot.com wrote:</p>
<p>This is another quoted quoted text reply</p>
<p>This is nice</p>
<p>On Mon, Sep 29, 2025 at 4:21 PM John from Shaneforwoot &lt; &gt; shaneforwoot@gmail.com&gt; wrote:</p>
<p>Hey there, this is a reply from Chatwoot, notice the quoted text</p>
<p>Hey there</p>
<p>This is an email text, enjoy reading this</p>
<p>-- Shivam Mishra, Chatwoot</p>
</blockquote>
</blockquote>
</blockquote>
`;

const EMAIL_WITH_SIGNATURE = `
<p>Latest reply here.</p>
<p>Thanks,</p>
<p>Jane Doe</p>
<blockquote>
  <p>On Mon, Sep 22, Someone wrote:</p>
  <p>Previous reply content</p>
</blockquote>
`;

const EMAIL_WITH_FOLLOW_UP_CONTENT = `
<blockquote>
  <p>Inline quote that should stay</p>
</blockquote>
<p>Internal note follows</p>
<p>Regards,</p>
`;

const NEW_RAW_FIXTURE_MATRIX = [
  {
    client: 'Gmail',
    kind: 'reply',
    metadata: { subject: 'Re: Dive plan' },
    html: `
      <div>Fresh Gmail reply</div>
      <div class="gmail_quote gmail_quote_container">
        <div class="gmail_attr">On Sun, Jul 26, 2026 at 9:30 AM Pat wrote:</div>
        <blockquote class="gmail_quote">Older Gmail reply</blockquote>
      </div>
    `,
    visibleText: ['Fresh Gmail reply'],
    hiddenText: ['Older Gmail reply'],
    hasQuotes: true,
  },
  {
    client: 'Gmail',
    kind: 'forward with a quoted reply below',
    metadata: { subject: 'Fwd: Dive plan' },
    html: `
      <div>For the dive team</div>
      <div class="gmail_quote gmail_quote_container">
        <div class="gmail_attr">---------- Forwarded message ---------</div>
        <div>Forwarded Gmail body</div>
        <blockquote>
          <div>On Sat, Jul 25, 2026 at 8:15 AM Sam wrote:</div>
          <div>Older reply inside the forwarded body</div>
        </blockquote>
      </div>
    `,
    visibleText: [
      'For the dive team',
      'Forwarded Gmail body',
      'Older reply inside the forwarded body',
    ],
    hiddenText: [],
    hasQuotes: false,
  },
  {
    client: 'Outlook',
    kind: 'reply',
    metadata: { subject: 'RE: Charter details' },
    html: `
      <div>Fresh Outlook reply</div>
      <div class="OutlookQuote">
        <div>From: Pat Example &lt;pat@example.com&gt;</div>
        <div>Sent: Sunday, July 26, 2026 9:30 AM</div>
        <div>Older Outlook reply</div>
      </div>
    `,
    visibleText: ['Fresh Outlook reply'],
    hiddenText: ['Older Outlook reply'],
    hasQuotes: true,
  },
  {
    client: 'Outlook',
    kind: 'forward',
    metadata: { subject: 'FW: Charter details' },
    html: `
      <div>Please review this Outlook message.</div>
      <div id="divRplyFwdMsg">
        <hr>
        <div>From: Pat Example &lt;pat@example.com&gt;</div>
        <div>Sent: Sunday, July 26, 2026 9:30 AM</div>
        <div>Forwarded Outlook body</div>
      </div>
    `,
    visibleText: [
      'Please review this Outlook message.',
      'Forwarded Outlook body',
    ],
    hiddenText: [],
    hasQuotes: false,
  },
  {
    client: 'Apple Mail',
    kind: 'reply',
    metadata: { subject: 'Re: Boat time' },
    html: `
      <div>Fresh Apple Mail reply</div>
      <blockquote type="cite">
        <div>On Jul 26, 2026, at 9:30 AM, Pat wrote:</div>
        <div>Older Apple Mail reply</div>
      </blockquote>
    `,
    visibleText: ['Fresh Apple Mail reply'],
    hiddenText: ['Older Apple Mail reply'],
    hasQuotes: true,
  },
  {
    client: 'Apple Mail',
    kind: 'forward',
    metadata: { subject: 'Fwd: Boat time' },
    html: `
      <div>For the captain</div>
      <blockquote type="cite">
        <div>Begin forwarded message:</div>
        <div>Forwarded Apple Mail body</div>
      </blockquote>
    `,
    visibleText: ['For the captain', 'Forwarded Apple Mail body'],
    hiddenText: [],
    hasQuotes: false,
  },
  {
    client: 'cPanel',
    kind: 'reply',
    metadata: { subject: 'Re: Equipment list' },
    html: `
      <p>Fresh cPanel reply</p>
      <blockquote type="cite">
        On 07/26/2026 9:30 AM, Pat wrote:
        <p>Older cPanel reply</p>
      </blockquote>
    `,
    visibleText: ['Fresh cPanel reply'],
    hiddenText: ['Older cPanel reply'],
    hasQuotes: true,
  },
  {
    client: 'cPanel',
    kind: 'forward',
    metadata: { subject: 'Fwd: Equipment list' },
    html: `
      <p>For the equipment team</p>
      <div>-------- Forwarded Message --------</div>
      <div>From: Pat Example &lt;pat@example.com&gt;</div>
      <div>Forwarded cPanel body</div>
    `,
    visibleText: ['For the equipment team', 'Forwarded cPanel body'],
    hiddenText: [],
    hasQuotes: false,
  },
];

const LEGACY_QUOTE_CSS = `
  <!-- chatwoot-bq-fix-v2 -->
  <style>
    blockquote { display: none !important; }
    .gmail_quote, .gmail_attr, div[class*="gmail_quote"], div[class*="gmail_attr"] { display: none !important; }
    div.OutlookMessageHeader, div[id*="reply_header"] { display: none !important; }
  </style>
`;

const LEGACY_FIXTURE = {
  metadata: { subject: 'Re: Historical reservation' },
  html: `
    ${LEGACY_QUOTE_CSS}
    <div>Fresh historical reply</div>
    <div class="gmail_quote gmail_quote_container">
      <div class="gmail_attr">On Sat, Jul 25, 2026 at 8:15 AM Pat wrote:</div>
      <blockquote class="gmail_quote">Historical quoted reply</blockquote>
    </div>
  `,
};

describe('EmailQuoteExtractor', () => {
  describe('new raw fixture matrix', () => {
    it.each(NEW_RAW_FIXTURE_MATRIX)(
      '$client $kind renders the accepted default body',
      fixture => {
        const renderedHtml = EmailQuoteExtractor.extractQuotes(
          fixture.html,
          fixture.metadata
        );
        const container = document.createElement('div');
        container.innerHTML = renderedHtml;

        fixture.visibleText.forEach(text => {
          expect(container.textContent).toContain(text);
        });
        fixture.hiddenText.forEach(text => {
          expect(container.textContent).not.toContain(text);
        });
        expect(
          EmailQuoteExtractor.hasQuotes(fixture.html, fixture.metadata)
        ).toBe(fixture.hasQuotes);
      }
    );
  });

  describe('historical legacy fixture', () => {
    it('strips the known legacy CSS marker and style at render time', () => {
      const renderableHtml = EmailQuoteExtractor.prepareForRender(
        LEGACY_FIXTURE.html
      );

      expect(renderableHtml).not.toContain('chatwoot-bq-fix-v2');
      expect(renderableHtml).not.toContain('display: none !important');
      expect(renderableHtml).toContain('Fresh historical reply');
      expect(renderableHtml).toContain('Historical quoted reply');
    });

    it('collapses the historical quoted reply after render-time stripping', () => {
      const renderableHtml = EmailQuoteExtractor.prepareForRender(
        LEGACY_FIXTURE.html
      );
      const renderedHtml = EmailQuoteExtractor.extractQuotes(
        renderableHtml,
        LEGACY_FIXTURE.metadata
      );

      expect(renderedHtml).toContain('Fresh historical reply');
      expect(renderedHtml).not.toContain('Historical quoted reply');
      expect(
        EmailQuoteExtractor.hasQuotes(renderableHtml, LEGACY_FIXTURE.metadata)
      ).toBe(true);
    });

    it('does not remove unmarked style elements from historical bodies', () => {
      const html =
        '<style>.reservation { color: blue; }</style><p>Reservation</p>';

      expect(EmailQuoteExtractor.prepareForRender(html)).toBe(html);
    });
  });

  it('removes blockquote-based quotes from the email body', () => {
    const cleanedHtml = EmailQuoteExtractor.extractQuotes(SAMPLE_EMAIL_HTML);

    const container = document.createElement('div');
    container.innerHTML = cleanedHtml;

    expect(container.querySelectorAll('blockquote').length).toBe(0);
    expect(container.textContent?.trim()).toBe('method');
    expect(container.textContent).not.toContain(
      'On Mon, Sep 29, 2025 at 5:18 PM'
    );
  });

  it('keeps blockquote fallback when it is not the last top-level element', () => {
    const cleanedHtml = EmailQuoteExtractor.extractQuotes(
      EMAIL_WITH_FOLLOW_UP_CONTENT
    );

    const container = document.createElement('div');
    container.innerHTML = cleanedHtml;

    expect(container.querySelector('blockquote')).not.toBeNull();
    expect(container.lastElementChild?.tagName).toBe('P');
  });

  it('detects quote indicators in nested blockquotes', () => {
    const result = EmailQuoteExtractor.hasQuotes(SAMPLE_EMAIL_HTML);
    expect(result).toBe(true);
  });

  it('does not flag blockquotes that are followed by other elements', () => {
    expect(EmailQuoteExtractor.hasQuotes(EMAIL_WITH_FOLLOW_UP_CONTENT)).toBe(
      false
    );
  });

  it('returns false when no quote indicators are present', () => {
    const html = '<p>Plain content</p>';
    expect(EmailQuoteExtractor.hasQuotes(html)).toBe(false);
  });

  it('removes trailing blockquotes while preserving trailing signatures', () => {
    const cleanedHtml = EmailQuoteExtractor.extractQuotes(EMAIL_WITH_SIGNATURE);

    expect(cleanedHtml).toContain('<p>Thanks,</p>');
    expect(cleanedHtml).toContain('<p>Jane Doe</p>');
    expect(cleanedHtml).not.toContain('<blockquote');
  });

  it('detects quotes for trailing blockquotes even when signatures follow text', () => {
    expect(EmailQuoteExtractor.hasQuotes(EMAIL_WITH_SIGNATURE)).toBe(true);
  });

  describe('HTML sanitization', () => {
    it('removes onerror handlers from img tags in extractQuotes', () => {
      const maliciousHtml = '<p>Hello</p><img src="x" onerror="alert(1)">';
      const cleanedHtml = EmailQuoteExtractor.extractQuotes(maliciousHtml);

      expect(cleanedHtml).not.toContain('onerror');
      expect(cleanedHtml).toContain('<p>Hello</p>');
    });

    it('removes onerror handlers from img tags in hasQuotes', () => {
      const maliciousHtml = '<p>Hello</p><img src="x" onerror="alert(1)">';
      // Should not throw and should safely check for quotes
      const result = EmailQuoteExtractor.hasQuotes(maliciousHtml);
      expect(result).toBe(false);
    });

    it('removes script tags in extractQuotes', () => {
      const maliciousHtml =
        '<p>Content</p><script>alert("xss")</script><p>More</p>';
      const cleanedHtml = EmailQuoteExtractor.extractQuotes(maliciousHtml);

      expect(cleanedHtml).not.toContain('<script');
      expect(cleanedHtml).not.toContain('alert');
      expect(cleanedHtml).toContain('<p>Content</p>');
      expect(cleanedHtml).toContain('<p>More</p>');
    });

    it('removes onclick handlers in extractQuotes', () => {
      const maliciousHtml = '<p onclick="alert(1)">Click me</p>';
      const cleanedHtml = EmailQuoteExtractor.extractQuotes(maliciousHtml);

      expect(cleanedHtml).not.toContain('onclick');
      expect(cleanedHtml).toContain('Click me');
    });

    it('removes javascript: URLs in extractQuotes', () => {
      const maliciousHtml = '<a href="javascript:alert(1)">Link</a>';
      const cleanedHtml = EmailQuoteExtractor.extractQuotes(maliciousHtml);

      // eslint-disable-next-line no-script-url
      expect(cleanedHtml).not.toContain('javascript:');
      expect(cleanedHtml).toContain('Link');
    });

    it('removes encoded payloads with event handlers in extractQuotes', () => {
      const maliciousHtml =
        '<img src="x" id="PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==" onerror="eval(atob(this.id))">';
      const cleanedHtml = EmailQuoteExtractor.extractQuotes(maliciousHtml);

      expect(cleanedHtml).not.toContain('onerror');
      expect(cleanedHtml).not.toContain('eval');
    });
  });
});
