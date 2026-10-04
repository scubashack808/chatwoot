import { format, parseISO, isValid as isValidDate } from 'date-fns';
import DOMPurify from 'dompurify';

/**
 * Extracts plain text from HTML content
 * @param {string} html - HTML content to convert
 * @returns {string} Plain text content
 */
export const extractPlainTextFromHtml = html => {
  if (!html) {
    return '';
  }
  if (typeof document === 'undefined') {
    return html.replace(/<[^>]*>/g, ' ');
  }
  const tempDiv = document.createElement('div');
  tempDiv.innerHTML = DOMPurify.sanitize(html);
  // Unlike EmailQuoteExtractor.flattenBlockText, which only needs line starts
  // for attribution matching, this output is shown to the agent, so it also
  // honours <br> and drops markup-indentation whitespace between blocks.
  const blockTags = new Set([
    'P',
    'DIV',
    'BLOCKQUOTE',
    'LI',
    'UL',
    'OL',
    'H1',
    'H2',
    'H3',
    'H4',
    'H5',
    'H6',
    'PRE',
    'TABLE',
    'TR',
    'HR',
    'SECTION',
    'ARTICLE',
    'HEADER',
    'FOOTER',
  ]);
  let text = '';
  // Defer block separators until text follows, avoiding outer/nested breaks.
  let pendingBoundary = false;

  const visit = node => {
    if (node.nodeType === Node.TEXT_NODE) {
      const isLayoutWhitespace =
        /^[\t\n\f\r ]*$/.test(node.textContent) &&
        (pendingBoundary || !text || text.endsWith('\n')) &&
        !node.parentElement?.closest('pre');
      if (node.textContent && !isLayoutWhitespace) {
        if (
          pendingBoundary &&
          text &&
          !text.endsWith('\n') &&
          !node.textContent.startsWith('\n')
        ) {
          text += '\n';
        }
        text += node.textContent;
        pendingBoundary = false;
      }
      return;
    }
    if (node.nodeName === 'BR') {
      text += '\n';
      pendingBoundary = false;
      return;
    }
    const isBlock = blockTags.has(node.nodeName);
    if (isBlock) pendingBoundary = true;
    node.childNodes.forEach(visit);
    if (isBlock) pendingBoundary = true;
  };

  tempDiv.childNodes.forEach(visit);
  return text;
};

/**
 * Extracts sender name from email message
 * @param {Object} lastEmail - Last email message object
 * @param {Object} contact - Contact object
 * @returns {string} Sender name
 */
export const getEmailSenderName = (lastEmail, contact) => {
  const senderName = lastEmail?.sender?.name;
  if (senderName && senderName.trim()) {
    return senderName.trim();
  }

  const contactName = contact?.name;
  return contactName && contactName.trim() ? contactName.trim() : '';
};

/**
 * Extracts sender email from email message
 * @param {Object} lastEmail - Last email message object
 * @param {Object} contact - Contact object
 * @returns {string} Sender email address
 */
export const getEmailSenderEmail = (lastEmail, contact) => {
  const senderEmail = lastEmail?.sender?.email;
  if (senderEmail && senderEmail.trim()) {
    return senderEmail.trim();
  }

  const contentAttributes =
    lastEmail?.contentAttributes || lastEmail?.content_attributes || {};
  const emailMeta = contentAttributes.email || {};

  if (Array.isArray(emailMeta.from) && emailMeta.from.length > 0) {
    const fromAddress = emailMeta.from[0];
    if (fromAddress && fromAddress.trim()) {
      return fromAddress.trim();
    }
  }

  const contactEmail = contact?.email;
  return contactEmail && contactEmail.trim() ? contactEmail.trim() : '';
};

/**
 * Extracts date from email message
 * @param {Object} lastEmail - Last email message object
 * @returns {Date|null} Email date
 */
export const getEmailDate = lastEmail => {
  const contentAttributes =
    lastEmail?.contentAttributes || lastEmail?.content_attributes || {};
  const emailMeta = contentAttributes.email || {};

  if (emailMeta.date) {
    const parsedDate = parseISO(emailMeta.date);
    if (isValidDate(parsedDate)) {
      return parsedDate;
    }
  }

  const createdAt = lastEmail?.created_at;
  if (createdAt) {
    const timestamp = Number(createdAt);
    if (!Number.isNaN(timestamp)) {
      const milliseconds = timestamp > 1e12 ? timestamp : timestamp * 1000;
      const derivedDate = new Date(milliseconds);
      if (!Number.isNaN(derivedDate.getTime())) {
        return derivedDate;
      }
    }
  }

  return null;
};

/**
 * Formats date for quoted email header
 * @param {Date} date - Date to format
 * @returns {string} Formatted date string
 */
export const formatQuotedEmailDate = date => {
  try {
    return format(date, "EEE, MMM d, yyyy 'at' p");
  } catch (error) {
    const fallbackDate = new Date(date);
    if (!Number.isNaN(fallbackDate.getTime())) {
      return format(fallbackDate, "EEE, MMM d, yyyy 'at' p");
    }
  }

  return '';
};

/**
 * Extracts inbox email address from last email message
 * @param {Object} lastEmail - Last email message object
 * @param {Object} inbox - Inbox object
 * @returns {string} Inbox email address
 */
export const getInboxEmail = (lastEmail, inbox) => {
  const contentAttributes =
    lastEmail?.contentAttributes || lastEmail?.content_attributes || {};
  const emailMeta = contentAttributes.email || {};

  if (Array.isArray(emailMeta.to) && emailMeta.to.length > 0) {
    const toAddress = emailMeta.to[0];
    if (toAddress && toAddress.trim()) {
      return toAddress.trim();
    }
  }

  const inboxEmail = inbox?.email;
  return inboxEmail && inboxEmail.trim() ? inboxEmail.trim() : '';
};

/**
 * Builds quoted email header from contact (for incoming messages)
 * @param {Object} lastEmail - Last email message object
 * @param {Object} contact - Contact object
 * @returns {string} Formatted header string
 */
export const buildQuotedEmailHeaderFromContact = (lastEmail, contact) => {
  if (!lastEmail) {
    return '';
  }

  const quotedDate = getEmailDate(lastEmail);
  const senderEmail = getEmailSenderEmail(lastEmail, contact);

  if (!quotedDate || !senderEmail) {
    return '';
  }

  const formattedDate = formatQuotedEmailDate(quotedDate);
  if (!formattedDate) {
    return '';
  }

  const senderName = getEmailSenderName(lastEmail, contact);
  const hasName = !!senderName;
  const contactLabel = hasName
    ? `${senderName} <${senderEmail}>`
    : `<${senderEmail}>`;

  return `On ${formattedDate} ${contactLabel} wrote:`;
};

/**
 * Builds quoted email header from inbox (for outgoing messages)
 * @param {Object} lastEmail - Last email message object
 * @param {Object} inbox - Inbox object
 * @returns {string} Formatted header string
 */
export const buildQuotedEmailHeaderFromInbox = (lastEmail, inbox) => {
  if (!lastEmail) {
    return '';
  }

  const quotedDate = getEmailDate(lastEmail);
  const inboxEmail = getInboxEmail(lastEmail, inbox);

  if (!quotedDate || !inboxEmail) {
    return '';
  }

  const formattedDate = formatQuotedEmailDate(quotedDate);
  if (!formattedDate) {
    return '';
  }

  const inboxName = inbox?.name;
  const hasName = !!inboxName;
  const inboxLabel = hasName
    ? `${inboxName} <${inboxEmail}>`
    : `<${inboxEmail}>`;

  return `On ${formattedDate} ${inboxLabel} wrote:`;
};

/**
 * Builds quoted email header based on message type
 * @param {Object} lastEmail - Last email message object
 * @param {Object} contact - Contact object
 * @param {Object} inbox - Inbox object
 * @returns {string} Formatted header string
 */
export const buildQuotedEmailHeader = (lastEmail, contact, inbox) => {
  if (!lastEmail) {
    return '';
  }

  // MESSAGE_TYPE.OUTGOING = 1, MESSAGE_TYPE.INCOMING = 0
  const isOutgoing = lastEmail.message_type === 1;

  if (isOutgoing) {
    return buildQuotedEmailHeaderFromInbox(lastEmail, inbox);
  }

  return buildQuotedEmailHeaderFromContact(lastEmail, contact);
};

/**
 * Formats text as markdown blockquote
 * @param {string} text - Text to format
 * @param {string} header - Optional header to prepend
 * @returns {string} Formatted blockquote
 */
export const formatQuotedTextAsBlockquote = (text, header = '') => {
  const normalizedLines = text
    ? String(text).replace(/\r\n/g, '\n').split('\n')
    : [];

  if (!header && !normalizedLines.length) {
    return '';
  }

  const quotedLines = [];

  if (header) {
    quotedLines.push(`> ${header}`);
    quotedLines.push('>');
  }

  normalizedLines.forEach(line => {
    const trimmedLine = line.trimEnd();
    quotedLines.push(trimmedLine ? `> ${trimmedLine}` : '>');
  });

  return quotedLines.join('\n');
};

/**
 * Extracts quoted email text from last email message
 * @param {Object} lastEmail - Last email message object
 * @returns {string} Quoted email text
 */
export const extractQuotedEmailText = lastEmail => {
  if (!lastEmail) {
    return '';
  }

  const contentAttributes =
    lastEmail.contentAttributes || lastEmail.content_attributes || {};
  const emailContent = contentAttributes.email || {};
  const textContent = emailContent.textContent || emailContent.text_content;

  if (textContent?.reply) {
    return textContent.reply;
  }
  if (textContent?.full) {
    return textContent.full;
  }

  const htmlContent = emailContent.htmlContent || emailContent.html_content;
  if (htmlContent?.reply) {
    return extractPlainTextFromHtml(htmlContent.reply);
  }
  if (htmlContent?.full) {
    return extractPlainTextFromHtml(htmlContent.full);
  }

  const fallbackContent =
    lastEmail.content || lastEmail.processed_message_content || '';

  return fallbackContent;
};

/**
 * Truncates text for preview display
 * @param {string} text - Text to truncate
 * @param {number} maxLength - Maximum length (default: 80)
 * @returns {string} Truncated text
 */
export const truncatePreviewText = (text, maxLength = 80) => {
  const preview = text.trim().replace(/\s+/g, ' ');
  if (!preview) {
    return '';
  }

  if (preview.length <= maxLength) {
    return preview;
  }
  return `${preview.slice(0, maxLength - 3)}...`;
};

/**
 * Appends quoted text to message
 * @param {string} message - Original message
 * @param {string} quotedText - Text to quote
 * @param {string} header - Quote header
 * @returns {string} Message with quoted text appended
 */
export const appendQuotedTextToMessage = (message, quotedText, header) => {
  const baseMessage = message ? String(message) : '';
  const quotedBlock = formatQuotedTextAsBlockquote(quotedText, header);

  if (!quotedBlock) {
    return baseMessage;
  }

  if (!baseMessage) {
    return quotedBlock;
  }

  let separator = '\n\n';
  if (baseMessage.endsWith('\n\n')) {
    separator = '';
  } else if (baseMessage.endsWith('\n')) {
    separator = '\n';
  }

  return `${baseMessage}${separator}${quotedBlock}`;
};
