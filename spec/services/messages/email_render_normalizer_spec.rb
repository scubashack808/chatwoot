require 'rails_helper'

RSpec.describe Messages::EmailRenderNormalizer do
  describe '.normalize' do
    let(:wrap) { ->(html) { { email: { html_content: { full: html } } } } }
    let(:body_of) { ->(result) { result[:email][:html_content][:full] } }

    it 'returns nil unchanged' do
      expect(described_class.normalize(nil)).to be_nil
    end

    it 'returns an empty hash unchanged' do
      expect(described_class.normalize({})).to eq({})
    end

    it 'returns content_attributes without an email hash unchanged' do
      attributes = { in_reply_to: 42, deleted: false }

      expect(described_class.normalize(attributes)).to eq(attributes)
    end

    it 'returns an email hash without html_content unchanged' do
      attributes = { email: { text_content: { full: 'plain' } } }

      expect(described_class.normalize(attributes)).to eq(attributes)
    end

    it 'returns the same object when the body has nothing to strip' do
      attributes = wrap.call('<div style="color: red;">hello</div>')

      expect(described_class.normalize(attributes)).to be(attributes)
    end

    it 'removes a height declaration from a style attribute' do
      result = described_class.normalize(wrap.call('<table style="height: 100%; color: red;">'))

      expect(body_of.call(result)).to eq('<table style="color: red;">')
    end

    it 'removes a height declaration written without spaces' do
      result = described_class.normalize(wrap.call('<table style="height:100%;color:red">'))

      expect(body_of.call(result)).to eq('<table style="color:red">')
    end

    it 'removes a height declaration carrying !important' do
      result = described_class.normalize(wrap.call('<td style="height: 100% !important; padding: 4px">'))

      expect(body_of.call(result)).to eq('<td style="padding: 4px">')
    end

    it 'removes a min-height declaration' do
      result = described_class.normalize(wrap.call('<table style="min-height:100%">'))

      expect(body_of.call(result)).to eq('<table style="">')
    end

    it 'removes a height declaration from a single quoted style attribute' do
      result = described_class.normalize(wrap.call("<table style='height: 100%; color: red'>"))

      expect(body_of.call(result)).to eq("<table style='color: red'>")
    end

    it 'removes a height attribute' do
      result = described_class.normalize(wrap.call('<table height="100%" width="600">'))

      expect(body_of.call(result)).to eq('<table width="600">')
    end

    it 'removes a single quoted height attribute' do
      result = described_class.normalize(wrap.call("<table height='100%' width='600'>"))

      expect(body_of.call(result)).to eq("<table width='600'>")
    end

    it 'removes an unquoted height attribute' do
      result = described_class.normalize(wrap.call('<table height=100% width=600>'))

      expect(body_of.call(result)).to eq('<table width=600>')
    end

    it 'removes height declarations inside a style block' do
      html = "<style>body { margin: 0 }\n.wrapper { height: 100% !important; background: #fff }</style><p>hi</p>"

      result = described_class.normalize(wrap.call(html))

      expect(body_of.call(result)).to eq("<style>body { margin: 0 }\n.wrapper { background: #fff }</style><p>hi</p>")
    end

    it 'is idempotent' do
      once = described_class.normalize(wrap.call('<table height="100%" style="height: 100%">'))
      twice = described_class.normalize(once)

      expect(body_of.call(twice)).to eq(body_of.call(once))
    end

    context 'when preserving non-target declarations' do
      it 'preserves max-height' do
        result = described_class.normalize(wrap.call('<img style="max-height: 100%">'))

        expect(body_of.call(result)).to eq('<img style="max-height: 100%">')
      end

      it 'preserves line-height' do
        result = described_class.normalize(wrap.call('<p style="line-height: 100%">text</p>'))

        expect(body_of.call(result)).to eq('<p style="line-height: 100%">text</p>')
      end

      it 'preserves a custom property named height' do
        result = described_class.normalize(wrap.call('<div style="--height: 100%">'))

        expect(body_of.call(result)).to eq('<div style="--height: 100%">')
      end

      it 'preserves a percentage height that is not 100' do
        result = described_class.normalize(wrap.call('<table style="height: 50%">'))

        expect(body_of.call(result)).to eq('<table style="height: 50%">')
      end

      it 'preserves a value that merely starts with 100%' do
        result = described_class.normalize(wrap.call('<table style="height: 100%foo">'))

        expect(body_of.call(result)).to eq('<table style="height: 100%foo">')
      end

      it 'preserves a pixel height' do
        result = described_class.normalize(wrap.call('<table height="600" style="height: 600px">'))

        expect(body_of.call(result)).to eq('<table height="600" style="height: 600px">')
      end

      it 'preserves a data-height attribute' do
        result = described_class.normalize(wrap.call('<div data-height="100%">'))

        expect(body_of.call(result)).to eq('<div data-height="100%">')
      end
    end

    context 'when preserving customer-visible content' do
      it 'preserves a height declaration written in customer prose' do
        html = '<p>Set the banner to height: 100% and it filled the screen.</p>'

        result = described_class.normalize(wrap.call(html))

        expect(body_of.call(result)).to eq(html)
      end

      it 'preserves a height attribute quoted in customer prose' do
        html = '<p>They sent height="100%" in the template.</p>'

        result = described_class.normalize(wrap.call(html))

        expect(body_of.call(result)).to eq(html)
      end

      it 'preserves markup examples inside a code block' do
        html = '<pre><code>&lt;table height="100%" style="height: 100%"&gt;</code></pre>'

        result = described_class.normalize(wrap.call(html))

        expect(body_of.call(result)).to eq(html)
      end

      it 'preserves a URL carrying the same characters' do
        html = '<a href="https://example.com/p?height=100%25&amp;style=height:100%25">report</a>'

        result = described_class.normalize(wrap.call(html))

        expect(body_of.call(result)).to eq(html)
      end

      it 'preserves an HTML comment' do
        html = '<!-- wrapper uses height: 100% here --><div>body</div>'

        result = described_class.normalize(wrap.call(html))

        expect(body_of.call(result)).to eq(html)
      end

      it 'keeps readable content in malformed email HTML' do
        html = '<div><p>Unclosed paragraph<table height="100%"><tr><td>Cell text</td></div>'

        result = described_class.normalize(wrap.call(html))

        expect(body_of.call(result)).to eq('<div><p>Unclosed paragraph<table><tr><td>Cell text</td></div>')
      end
    end

    context 'with a FareHarbor shaped reply' do
      let(:html) do
        <<~HTML
          <div dir="ltr">Yes, 9am works for us. See you Wednesday!</div>
          <div class="gmail_quote">
            <div dir="ltr" class="gmail_attr">On Tue, Aug 12, 2026 at 4:02 PM Extended Horizons &lt;info@example.com&gt; wrote:</div>
            <blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex">
              <table height="100%" width="100%" style="height: 100% !important; background: #f4f4f4">
                <tr><td><img src="https://cdn.example.com/logo.png" alt="Extended Horizons"></td></tr>
                <tr><td>Guided Shore Dive on Wednesday, August 19 at 9:00am</td></tr>
                <tr><td><a href="https://fareharbor.com/embeds/book/xyz/">Manage your booking</a></td></tr>
              </table>
            </blockquote>
          </div>
        HTML
      end

      let(:normalized) { body_of.call(described_class.normalize(wrap.call(html))) }

      it 'removes the full height attribute and declaration' do
        expect(normalized).not_to include('height="100%"')
        expect(normalized).not_to include('height: 100% !important')
      end

      it 'preserves the customer reply' do
        expect(normalized).to include('Yes, 9am works for us. See you Wednesday!')
      end

      it 'preserves the quoted history and its markup' do
        expect(normalized).to include('class="gmail_quote"')
        expect(normalized).to include('Guided Shore Dive on Wednesday, August 19 at 9:00am')
      end

      it 'preserves links, images and other styles' do
        expect(normalized).to include('href="https://fareharbor.com/embeds/book/xyz/"')
        expect(normalized).to include('src="https://cdn.example.com/logo.png"')
        expect(normalized).to include('background: #f4f4f4')
        expect(normalized).to include('width="100%"')
        expect(normalized).to include('border-left:1px solid #ccc')
      end
    end

    context 'with string keys, as a reloaded record yields' do
      let(:attributes) { { 'email' => { 'html_content' => { 'full' => '<table height="100%">', 'reply' => 'hi' } } } }

      it 'strips the declaration' do
        expect(described_class.normalize(attributes).dig('email', 'html_content', 'full')).to eq('<table>')
      end

      it 'does not change the key shape' do
        expect(described_class.normalize(attributes)['email']['html_content'].keys).to eq(%w[full reply])
      end
    end

    it 'does not mutate the hash it was given' do
      attributes = wrap.call('<table height="100%">')

      described_class.normalize(attributes)

      expect(body_of.call(attributes)).to eq('<table height="100%">')
    end

    # A mail body is attacker-chosen and uncapped on the way in, and this runs on every read, so a
    # body that never closes a <style> must not be able to make the scan superlinear. Before the
    # segment regexes were bounded, 128KB of this shape took over 17 seconds.
    context 'with a body that never closes a style or script tag' do
      let(:elapsed) do
        lambda do |attributes|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          described_class.normalize(attributes)
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end
      end

      # The bound is loose on purpose: this has to survive a loaded CI shard, and it is still two
      # orders of magnitude below the quadratic behaviour it guards against.
      it 'normalizes a large unclosed style run quickly' do
        expect(elapsed.call(wrap.call('<style>' * 18_000))).to be < 2
      end

      it 'normalizes a large unclosed script run quickly' do
        expect(elapsed.call(wrap.call('<script>' * 16_000))).to be < 2
      end

      it 'still strips declarations that follow the unclosed tag' do
        result = described_class.normalize(wrap.call('<style><td style="height: 100%; color: red;">'))

        expect(body_of.call(result)).to eq('<style><td style="color: red;">')
      end

      it 'leaves the unclosed tag itself in place' do
        expect(body_of.call(described_class.normalize(wrap.call('<style>body{height:100%}<td height="100%">'))))
          .to eq('<style>body{height:100%}<td>')
      end
    end

    it 'strips both style blocks when a document has several' do
      html = '<style>a{height:100%}</style><p>mid</p><style>b{min-height: 100%;}</style>'

      expect(body_of.call(described_class.normalize(wrap.call(html)))).to eq('<style>a{}</style><p>mid</p><style>b{}</style>')
    end

    it 'leaves reply, quoted and text_content untouched' do
      attributes = {
        email: {
          html_content: { full: '<table height="100%">', reply: '<p style="height: 100%">reply</p>', quoted: 'quoted' },
          text_content: { full: 'height: 100%' }
        }
      }

      result = described_class.normalize(attributes)

      expect(result[:email][:html_content][:reply]).to eq('<p style="height: 100%">reply</p>')
      expect(result[:email][:html_content][:quoted]).to eq('quoted')
      expect(result[:email][:text_content][:full]).to eq('height: 100%')
    end
  end
end
