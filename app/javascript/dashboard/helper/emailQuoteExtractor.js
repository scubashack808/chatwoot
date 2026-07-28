import DOMPurify from 'dompurify';

// Quote detection strategies
const QUOTE_INDICATORS = [
  '.gmail_quote_container',
  '.gmail_quote',
  '.OutlookQuote',
  '.email-quote',
  '.quoted-text',
  '.quote',
  '[class*="quote"]',
  '[class*="Quote"]',
];

const BLOCKQUOTE_FALLBACK_SELECTOR = 'blockquote';

const LEGACY_QUOTE_CSS_PATTERN =
  /<!--\s*chatwoot-bq-fix-v2\s*-->\s*<style\b[^>]*>[\s\S]*?<\/style\s*>/gi;

// Forward prefixes across the clients we see, including the common non-English
// Outlook prefixes (WG, TR, RV, VS, Enc, I). A false positive here only costs a
// collapse that could have happened, while a false negative can hide forwarded
// content, so the pattern errs wide.
const FORWARDED_SUBJECT_PATTERN = /^\s*(fwd?|wg|tr|rv|vs|enc|i)\s*:/i;
const FORWARDED_BODY_PATTERNS = [
  /-{2,}\s*Forwarded message\s*-{2,}/i,
  /Begin forwarded message:/i,
];

// Attribution lines that only ever introduce quoted reply history. Deliberately
// narrower than QUOTE_PATTERNS below: "From:" and "Sent:" also appear inside a
// forward's own attribution block, so they cannot order forward evidence against
// reply evidence.
const REPLY_ATTRIBUTION_PATTERNS = [
  /On .* wrote:/i,
  /-----Original Message-----/i,
];

// Regex patterns for quote identification
const QUOTE_PATTERNS = [
  /On .* wrote:/i,
  /-----Original Message-----/i,
  /Sent: /i,
  /From: /i,
];

export class EmailQuoteExtractor {
  /**
   * Remove quotes from email HTML and return cleaned HTML
   * @param {string} htmlContent - Full HTML content of the email
   * @param {Object} emailMetadata - Stored email metadata used to identify forwards
   * @returns {string} HTML content with quotes removed
   */
  static extractQuotes(htmlContent, emailMetadata = {}) {
    // Create a temporary DOM element to parse HTML
    const tempDiv = document.createElement('div');
    tempDiv.innerHTML = DOMPurify.sanitize(this.prepareForRender(htmlContent));

    if (this.isForwardedEmail(tempDiv, emailMetadata)) {
      return tempDiv.innerHTML;
    }

    // Remove elements matching class selectors
    QUOTE_INDICATORS.forEach(selector => {
      tempDiv.querySelectorAll(selector).forEach(el => {
        el.remove();
      });
    });

    this.removeTrailingBlockquote(tempDiv);

    // Remove text-based quotes
    const textNodeQuotes = this.findTextNodeQuotes(tempDiv);
    textNodeQuotes.forEach(el => {
      el.remove();
    });

    return tempDiv.innerHTML;
  }

  /**
   * Check if HTML content contains any quotes
   * @param {string} htmlContent - Full HTML content of the email
   * @param {Object} emailMetadata - Stored email metadata used to identify forwards
   * @returns {boolean} True if quotes are detected, false otherwise
   */
  static hasQuotes(htmlContent, emailMetadata = {}) {
    const tempDiv = document.createElement('div');
    tempDiv.innerHTML = DOMPurify.sanitize(this.prepareForRender(htmlContent));

    if (this.isForwardedEmail(tempDiv, emailMetadata)) {
      return false;
    }

    // Check for class-based quotes
    // eslint-disable-next-line no-restricted-syntax
    for (const selector of QUOTE_INDICATORS) {
      if (tempDiv.querySelector(selector)) {
        return true;
      }
    }

    if (this.findTrailingBlockquote(tempDiv)) {
      return true;
    }

    // Check for text-based quotes
    const textNodeQuotes = this.findTextNodeQuotes(tempDiv);
    return textNodeQuotes.length > 0;
  }

  /**
   * Remove the known legacy quote-hiding style block before rendering.
   * @param {string} htmlContent - Full HTML content of the email
   * @returns {string} HTML content without the legacy injected style
   */
  static prepareForRender(htmlContent) {
    return (htmlContent || '').replace(LEGACY_QUOTE_CSS_PATTERN, '');
  }

  /**
   * Determine whether the email body is forwarded content rather than a reply quote.
   *
   * The tie-breaker for every ambiguous case is: never hide forwarded content.
   * Over-showing a quote chain that could have collapsed is the acceptable failure.
   * That is why the checks run in this order:
   *
   * 1. A forward prefix in the subject is the sender declaring this message is a
   *    forward, so it wins outright. It stays ahead of the inReplyTo check on
   *    purpose: a genuine forward can be sent inside a thread and carry
   *    In-Reply-To, so letting that header outrank the subject would collapse
   *    forwarded content.
   * 2. A known In-Reply-To means the client told us this is a reply.
   * 3. Otherwise fall back to body markers, scoped by hasOwnForwardMarker so that
   *    quoted history cannot decide the classification.
   *
   * @param {Element} rootElement - Parsed email body
   * @param {Object} emailMetadata - Stored email metadata
   * @returns {boolean} True if the email is a forward
   */
  static isForwardedEmail(rootElement, emailMetadata) {
    if (FORWARDED_SUBJECT_PATTERN.test(emailMetadata?.subject || '')) {
      return true;
    }

    if (emailMetadata?.inReplyTo) {
      return false;
    }

    return this.hasOwnForwardMarker(rootElement);
  }

  /**
   * Decide whether a forward marker in the body belongs to this message or to the
   * reply history it quotes.
   *
   * A marker that appears after a reply attribution line sits inside quoted
   * history, which is the shape of a reply that quotes a forward rather than a
   * forward. When the marker comes first, or when there is no attribution at all,
   * it is treated as this message's own marker, because the tie-breaker is to
   * never hide forwarded content.
   * @param {Element} rootElement - Parsed email body
   * @returns {boolean} True if a forward marker belongs to this message
   */
  static hasOwnForwardMarker(rootElement) {
    const body = rootElement.textContent || '';
    const forwardIndex = this.firstMatchIndex(body, FORWARDED_BODY_PATTERNS);

    if (forwardIndex === -1) {
      return false;
    }

    const replyIndex = this.firstMatchIndex(body, REPLY_ATTRIBUTION_PATTERNS);
    return replyIndex === -1 || forwardIndex < replyIndex;
  }

  /**
   * Index of the earliest match of any pattern, or -1 when none match.
   * @param {string} text - Text to search
   * @param {RegExp[]} patterns - Patterns to search for
   * @returns {number} Earliest match index, or -1 when nothing matches
   */
  static firstMatchIndex(text, patterns) {
    return patterns.reduce((earliest, pattern) => {
      const index = text.search(pattern);
      if (index === -1) {
        return earliest;
      }
      return earliest === -1 ? index : Math.min(earliest, index);
    }, -1);
  }

  /**
   * Find text nodes that match quote patterns
   * @param {Element} rootElement - Root element to search
   * @returns {Element[]} Array of parent block elements containing quote-like text
   */
  static findTextNodeQuotes(rootElement) {
    const quoteBlocks = [];
    const treeWalker = document.createTreeWalker(
      rootElement,
      NodeFilter.SHOW_TEXT,
      null,
      false
    );

    for (
      let currentNode = treeWalker.nextNode();
      currentNode !== null;
      currentNode = treeWalker.nextNode()
    ) {
      const isQuoteLike = QUOTE_PATTERNS.some(pattern =>
        pattern.test(currentNode.textContent)
      );

      if (isQuoteLike) {
        const parentBlock = this.findParentBlock(currentNode);
        if (parentBlock && !quoteBlocks.includes(parentBlock)) {
          quoteBlocks.push(parentBlock);
        }
      }
    }

    return quoteBlocks;
  }

  /**
   * Find the closest block-level parent element by recursively traversing up the DOM tree.
   * This method searches for common block-level elements like DIV, P, BLOCKQUOTE, and SECTION
   * that contain the text node. It's used to identify and remove entire block-level elements
   * that contain quote-like text, rather than just removing the text node itself. This ensures
   * proper structural removal of quoted content while maintaining HTML integrity.
   * @param {Node} node - Starting node to find parent
   * @returns {Element|null} Block-level parent element
   */
  static findParentBlock(node) {
    const blockElements = ['DIV', 'P', 'BLOCKQUOTE', 'SECTION'];
    let current = node.parentElement;

    while (current) {
      if (blockElements.includes(current.tagName)) {
        return current;
      }
      current = current.parentElement;
    }

    return null;
  }

  /**
   * Remove fallback blockquote if it is the last top-level element.
   * @param {Element} rootElement - Root element containing the HTML
   */
  static removeTrailingBlockquote(rootElement) {
    const trailingBlockquote = this.findTrailingBlockquote(rootElement);
    trailingBlockquote?.remove();
  }

  /**
   * Locate a fallback blockquote that is the last top-level element.
   * @param {Element} rootElement - Root element containing the HTML
   * @returns {Element|null} The trailing blockquote element if present
   */
  static findTrailingBlockquote(rootElement) {
    const lastElement = rootElement.lastElementChild;
    if (lastElement?.matches?.(BLOCKQUOTE_FALLBACK_SELECTOR)) {
      return lastElement;
    }
    return null;
  }
}
