# Strips viewport-expanding height declarations from the email body as it is served.
#
# A mail body that declares height: 100% on a wrapper table is asking to fill its viewport. The
# official mobile app renders incoming email by handing html_content.full to a non-scrolling
# auto-height WebView, and its own attempt to defuse this only replaces the exact literal
# "height:100%;" - which matches none of the spellings real mail uses. Removing them here fixes
# every client at once, on every delivery path.
#
# This runs at read time on purpose: the affected messages are already stored, and the raw mail
# must stay byte-identical on the row. Nothing is mutated; callers get a new hash.
#
# Scope is deliberately narrow. Only the height and min-height properties, only the exact value
# 100%, and only inside real markup: element attributes and <style> blocks. Text nodes, comments
# and scripts are passed through untouched, because customer prose, quoted code and URLs can all
# legitimately contain the same characters.
class Messages::EmailRenderNormalizer
  COMMENT = /<!--.*?-->/m
  STYLE_BLOCK = %r{<style\b[^>]*>.*?</style\s*>}mi
  SCRIPT_BLOCK = %r{<script\b[^>]*>.*?</script\s*>}mi
  TAG = /<[^>]+>/m
  # Ordered: a <style> body must be recognised as a block before its opening tag matches as a tag.
  MARKUP_SEGMENT = Regexp.union(COMMENT, STYLE_BLOCK, SCRIPT_BLOCK, TAG)

  STYLE_BLOCK_PARTS = %r{\A(<style\b[^>]*>)(.*)(</style\s*>)\z}mi
  # The lookbehind keeps max-height, line-height and --height custom properties out of the match.
  # The lookahead after 100% keeps values that merely start with it, such as 100%foo, intact.
  FULL_HEIGHT_DECLARATION = /(?<![-\w])(?:min-)?height\s*:\s*100%(?![\w%.-])\s*(?:!\s*important)?\s*;?\s*/i
  FULL_HEIGHT_ATTRIBUTE = %r{\sheight\s*=\s*(?:"100%"|'100%'|100%)(?=[\s>/]|\z)}i
  STYLE_ATTRIBUTE = /(\sstyle\s*=\s*)(?:"([^"]*)"|'([^']*)')/i

  class << self
    def normalize(content_attributes)
      email = fetch(content_attributes, :email)
      html_content = fetch(email, :html_content)
      body = fetch(html_content, :full)
      return content_attributes unless body.is_a?(String)

      normalized = strip_full_height(body)
      return content_attributes if normalized == body

      put(content_attributes, :email, put(email, :html_content, put(html_content, :full, normalized)))
    end

    private

    # content_attributes is a JSON-backed store, so a reloaded record yields string keys while a
    # record built in memory yields symbols. Both shapes reach push_event_data.
    def fetch(hash, key)
      return nil unless hash.is_a?(Hash)

      hash.key?(key) ? hash[key] : hash[key.to_s]
    end

    # merge returns a new hash, so the caller's nested hashes and the stored row are left alone.
    def put(hash, key, value)
      hash.merge((hash.key?(key) ? key : key.to_s) => value)
    end

    def strip_full_height(body)
      body.gsub(MARKUP_SEGMENT) do |segment|
        case segment
        when COMMENT, SCRIPT_BLOCK then segment
        when STYLE_BLOCK then strip_style_block(segment)
        else strip_tag(segment)
        end
      end
    end

    def strip_style_block(block)
      block.sub(STYLE_BLOCK_PARTS) do
        open_tag, css, close_tag = Regexp.last_match.captures
        "#{open_tag}#{strip_declarations(css)}#{close_tag}"
      end
    end

    def strip_tag(tag)
      tag.gsub(STYLE_ATTRIBUTE) do
        prefix, double_quoted, single_quoted = Regexp.last_match.captures
        quote = double_quoted ? '"' : "'"
        "#{prefix}#{quote}#{strip_declarations(double_quoted || single_quoted)}#{quote}"
      end.gsub(FULL_HEIGHT_ATTRIBUTE, '')
    end

    def strip_declarations(css)
      css.gsub(FULL_HEIGHT_DECLARATION, '')
    end
  end
end
