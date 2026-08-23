/**
 * Verbatim stored HTML from a real production row that carries the historical
 * `chatwoot-bq-fix-v2` quote-hiding style, captured by a read-only pull recorded in
 * research/receipts/PR11-2026-07-27-production-marker-sample.txt.
 *
 * Shape of the real bytes: the marker comment starts at position 1 of
 * email.html_content.full, followed by a single style element holding three rules,
 * then the message body and its Gmail quote container. 1,969 stored messages across
 * 1,414 conversations carry this shape.
 *
 * These bytes are the assertion of record for the legacy strip. They are byte-identical to
 * the captured row apart from CRLF normalization: the repo lint pipeline rewrites CR out of
 * a source file, so the two CRLF breaks in the mail body arrive here as LF, 972 characters
 * against the row's 974. The non-ASCII inventory (U+202F, the emoji) is preserved exactly,
 * and the marker and style region the strip targets is LF in the row itself. Do not
 * reformat them further: a fixture edited to match the regex proves nothing about production.
 *
 * The body carries a narrow no-break space (U+202F) in the Gmail attribution line,
 * which is why no-irregular-whitespace is disabled here. Real mail contains
 * characters a hand-written fixture would never include, and normalizing them away
 * would defeat the purpose of capturing the row verbatim.
 */
/* eslint-disable no-irregular-whitespace */
// prettier-ignore
export const PRODUCTION_LEGACY_QUOTE_CSS_HTML = `<!-- chatwoot-bq-fix-v2 -->
<style>
  blockquote { display: none !important; }
  .gmail_quote, .gmail_attr, div[class*="gmail_quote"], div[class*="gmail_attr"] { display: none !important; }
  div.OutlookMessageHeader, div[id*="reply_header"] { display: none !important; }
</style>
<div dir="ltr">Now we&#39;re cooking with fire. This is much more up my steam. Here&#39;s something to keep it tasty.🥭</div><br><div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">On Tue, Apr 28, 2026 at 4:01 PM A-Team from Ethan Extended Horizons &lt;<a href="mailto:ethan@extendedhorizons.com">ethan@extendedhorizons.com</a>&gt; wrote:<br></div><blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex"><p>This is more or less just a test message, if I&#39;m being honest. Sometimes I think about clouds as they roll over the sun, as if a blanket is covering a beach ball.</p>

</blockquote></div>`;
