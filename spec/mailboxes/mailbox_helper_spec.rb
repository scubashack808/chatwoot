require 'rails_helper'

RSpec.describe MailboxHelper do
  include ActionMailbox::TestHelper

  # Setup anonymous class
  let(:mailbox_helper_obj) do
    Class.new do
      include MailboxHelper
      attr_accessor :conversation, :processed_mail

      def initialize(conversation, processed_mail)
        @conversation = conversation
        @processed_mail = processed_mail
      end
    end
  end

  let(:mail) { create_inbound_email_from_fixture('welcome.eml').mail }
  let(:processed_mail) { MailPresenter.new(mail) }
  let(:conversation) { create(:conversation) }
  let(:dummy_message) { create(:message) }

  describe '#create_message' do
    before do
      create_list(:message, 5, conversation: conversation)
    end

    context 'when message already exist' do
      it 'creates a new message' do
        helper_instance = mailbox_helper_obj.new(conversation, processed_mail)

        expect(conversation.messages).to receive(:find_by).with(source_id: processed_mail.message_id).and_return(dummy_message)
        expect(conversation.messages).not_to receive(:create!)

        helper_instance.send(:create_message)
      end
    end

    context 'when message does not exist' do
      it 'creates a new message' do
        helper_instance = mailbox_helper_obj.new(conversation, processed_mail)

        expect(conversation.messages).to receive(:find_by).with(source_id: processed_mail.message_id).and_return(nil)
        expect(conversation.messages).to receive(:create!)

        helper_instance.send(:create_message)
      end
    end

    context 'when message data contains null bytes' do
      let(:mail) do
        mail = Mail.new
        mail.from = 'Sender <sender@example.com>'
        mail.to = 'Inbox <inbox@example.com>'
        mail.subject = "Hello\u0000"
        mail.message_id = "message\u0000@example.com"
        mail.content_type = 'text/plain'
        mail.body = "Body\u0000 text"
        mail
      end

      it 'creates the message with sanitized values' do
        helper_instance = mailbox_helper_obj.new(conversation, processed_mail)

        expect { helper_instance.send(:create_message) }.to change(conversation.messages, :count).by(1)

        message = conversation.messages.last
        expect(message.source_id).to eq('message@example.com')
        expect(message.content).to eq('Body text')
        expect(message.content_attributes.dig('email', 'message_id')).to eq('message@example.com')
        expect(message.content_attributes.to_json).not_to include('\u0000')
      end
    end
  end

  describe '#embed_plain_text_email_with_inline_image' do
    let(:mail_attachment) do
      {
        original: OpenStruct.new(filename: 'image.png'),
        blob: get_blob_for('spec/assets/avatar.png', 'image/png')
      }
    end

    let(:helper_instance) { mailbox_helper_obj.new(conversation, processed_mail) }

    it 'replaces the image tag in the text content' do
      helper_instance.instance_variable_set(:@text_content, 'Hello [image: image.png] World')
      helper_instance.send(:embed_plain_text_email_with_inline_image, mail_attachment)

      text_content = helper_instance.instance_variable_get(:@text_content)

      expect(text_content).to include(Rails.application.routes.url_helpers.url_for(mail_attachment[:blob]))
      expect(text_content).not_to include('[image: avatar.png]')
    end

    it 'replaces the image tag in the text content even if there is not tag to replace' do
      helper_instance.instance_variable_set(:@text_content, 'Hello World')
      helper_instance.send(:embed_plain_text_email_with_inline_image, mail_attachment)

      text_content = helper_instance.instance_variable_get(:@text_content)
      expect(text_content).to include(Rails.application.routes.url_helpers.url_for(mail_attachment[:blob]))
    end
  end

  describe '#body_references_cid?' do
    let(:helper_instance) { mailbox_helper_obj.new(conversation, processed_mail) }

    it 'detects percent-encoded CID references in HTML content' do
      helper_instance.instance_variable_set(:@html_content, '<img src="cid:image001.jpg%40test">')

      expect(helper_instance.send(:body_references_cid?, 'image001.jpg@test')).to be true
    end

    it 'matches the CID URI scheme case-insensitively without changing Content-ID matching' do
      helper_instance.instance_variable_set(:@html_content, '<img src="CiD:image001.jpg%40test">')

      expect(helper_instance.send(:body_references_cid?, 'image001.jpg@test')).to be true
      expect(helper_instance.send(:body_references_cid?, 'IMAGE001.jpg@test')).to be false
    end
  end

  describe '#inline_attachment?' do
    let(:helper_instance) { mailbox_helper_obj.new(conversation, processed_mail) }

    before do
      allow(helper_instance).to receive(:mail_content).and_return('Email body')
    end

    it 'detects inline images when the HTML body references the CID' do
      original_attachment = instance_double(Mail::Part, content_type: 'image/png', inline?: true, cid: 'image001.jpg@test')
      helper_instance.instance_variable_set(:@html_content, '<img src="cid:image001.jpg@test">')

      expect(helper_instance.send(:inline_attachment?, { original: original_attachment })).to be true
    end

    it 'does not detect inline-marked images when the HTML body does not reference the CID' do
      original_attachment = instance_double(Mail::Part, content_type: 'image/png', inline?: true, cid: 'image001.jpg@test')
      helper_instance.instance_variable_set(:@html_content, '<attachment id="image001.jpg@test"></attachment>')

      expect(helper_instance.send(:inline_attachment?, { original: original_attachment })).to be false
    end

    it 'does not detect non-image inline parts as inline attachments' do
      original_attachment = instance_double(Mail::Part, content_type: 'application/pdf', inline?: true, cid: 'document001@test')
      helper_instance.instance_variable_set(:@html_content, '<img src="cid:document001@test">')

      expect(helper_instance.send(:inline_attachment?, { original: original_attachment })).to be false
    end

    it 'keeps inline-marked images inline when HTML content is missing' do
      original_attachment = instance_double(Mail::Part, content_type: 'image/png', inline?: true, cid: 'image001.jpg@test')
      helper_instance.instance_variable_set(:@html_content, nil)

      expect { helper_instance.send(:inline_attachment?, { original: original_attachment }) }.not_to raise_error
      # With no HTML body there is nothing to reference the image, so an
      # explicitly inline-marked image stays inline rather than being surfaced.
      expect(helper_instance.send(:inline_attachment?, { original: original_attachment })).to be true
    end
  end

  describe '#upload_inline_image' do
    let(:mail_attachment) do
      {
        original: OpenStruct.new(cid: 'image001.jpg@test'),
        blob: get_blob_for('spec/assets/avatar.png', 'image/png')
      }
    end
    let(:helper_instance) { mailbox_helper_obj.new(conversation, processed_mail) }

    it 'replaces percent-encoded CID references in HTML content' do
      allow(Rails.application.routes.url_helpers).to receive(:url_for).and_return('/fake-image-url')
      helper_instance.instance_variable_set(:@html_content, '<img src="cid:image001.jpg%40test">')

      helper_instance.send(:upload_inline_image, mail_attachment)

      html_content = helper_instance.instance_variable_get(:@html_content)
      expect(html_content).to include('/fake-image-url"')
      expect(html_content).not_to include('cid:')
    end

    it 'replaces CID references with mixed-case URI schemes' do
      allow(Rails.application.routes.url_helpers).to receive(:url_for).and_return('/fake-image-url')
      helper_instance.instance_variable_set(:@html_content, '<img src="CID:image001.jpg%40test">')

      helper_instance.send(:upload_inline_image, mail_attachment)

      html_content = helper_instance.instance_variable_get(:@html_content)
      expect(html_content).to include('/fake-image-url"')
      expect(html_content).not_to match(/cid:/i)
    end
  end

  describe 'exact CID matching' do
    let(:helper_instance) { mailbox_helper_obj.new(conversation, processed_mail) }
    let(:cid) { 'image/name@test' }
    let(:mail_attachment) { { original: OpenStruct.new(cid: cid), blob: nil } }

    delimiters = ['"', "'", ' ', '>', '<', ')', "\n", '']
    suffixes = ['a', '2', '.', '-', '_', '/', '%2F']
    ['image/name@test', 'image%2Fname%40test', 'image%2fname%40test'].each do |reference|
      delimiters.each do |delimiter|
        it "preserves the delimiter after #{reference.inspect} followed by #{delimiter.inspect}" do
          html = "CiD:#{reference}#{delimiter}"
          helper_instance.instance_variable_set(:@html_content, html)
          allow(helper_instance).to receive(:inline_image_url).and_return('/image.png')

          expect(helper_instance.send(:body_references_cid?, cid)).to be true
          helper_instance.send(:upload_inline_image, mail_attachment)
          expect(helper_instance.instance_variable_get(:@html_content)).to eq("/image.png#{delimiter}")
        end
      end

      suffixes.each do |suffix|
        it "does not match or replace the prefix of #{reference}#{suffix}" do
          html = "<img src=\"cid:#{reference}#{suffix}\">"
          helper_instance.instance_variable_set(:@html_content, html)
          allow(helper_instance).to receive(:inline_image_url).and_return('/image.png')

          expect(helper_instance.send(:body_references_cid?, cid)).to be false
          helper_instance.send(:upload_inline_image, mail_attachment)
          expect(helper_instance.instance_variable_get(:@html_content)).to eq(html)
        end
      end
    end

    it 'matches and replaces unquoted CSS url(cid:...) references' do
      html = %(<td style="background:url(cid:#{cid})"><td style="background:url(cid:#{cid}2)">)
      helper_instance.instance_variable_set(:@html_content, html)
      allow(helper_instance).to receive(:inline_image_url).and_return('/image.png')

      expect(helper_instance.send(:body_references_cid?, cid)).to be true
      helper_instance.send(:upload_inline_image, mail_attachment)
      expect(helper_instance.instance_variable_get(:@html_content))
        .to eq(%(<td style="background:url(/image.png)"><td style="background:url(cid:#{cid}2)">))
    end

    it 'replaces repeated exact references without changing longer references or surrounding HTML' do
      html = %(<img src="cid:#{cid}"><img src='CID:#{cid}'><img src=cid:#{cid} ><img src="cid:#{cid}2">)
      helper_instance.instance_variable_set(:@html_content, html)
      allow(helper_instance).to receive(:inline_image_url).and_return('/image.png')

      helper_instance.send(:upload_inline_image, mail_attachment)

      expect(helper_instance.instance_variable_get(:@html_content)).to eq(
        %(<img src="/image.png"><img src='/image.png'><img src=/image.png ><img src="cid:#{cid}2">)
      )
    end
  end

  describe '#add_attachments_to_message' do
    let(:mail) { create_inbound_email_from_fixture('cid_inline_images_without_disposition.eml').mail }
    let(:processed_mail) { MailPresenter.new(mail) }
    let(:conversation) { create(:conversation) }
    let(:helper_instance) { mailbox_helper_obj.new(conversation, processed_mail) }

    before do
      helper_instance.send(:create_message)
    end

    it 'detects inline image attachment by cid reference when Content-Disposition is missing' do
      allow(Rails.application.routes.url_helpers).to receive(:url_for).and_return('/fake-image-url')
      helper_instance.send(:add_attachments_to_message)

      message = conversation.messages[0]

      expect(message.attachments.count).to eq(0)

      html_content = message.content_attributes[:email][:html_content][:full]

      expect(html_content).to include('/fake-image-url"')
      expect(html_content).not_to include('cid:')
    end

    {
      'short CID first' => [['photo@sender.test', 'photo@sender.test2'], 'cid:photo@sender.test2'],
      'long CID first' => [['photo@sender.test2', 'photo@sender.test'], 'cid:photo@sender.test2'],
      'disjoint CIDs' => [['other@sender.test', 'photo@sender.test2'], 'cid:photo@sender.test2'],
      'percent-encoded exact CID' => [['photo@sender.test2'], 'CID:photo%40sender.test2']
    }.each do |scenario, (ids, reference)|
      context "with #{scenario}" do
        let(:mail) do
          mime = Mail.new
          mime.from = 'Sender <sender@example.com>'
          mime.to = 'Inbox <inbox@example.com>'
          mime.subject = 'Exact inline image reference'
          mime.message_id = '<exact-inline-image@example.com>'
          mime.text_part = Mail::Part.new { body 'Ordinary email body.' }
          mime.html_part = Mail::Part.new do
            content_type 'text/html; charset=UTF-8'
            body %(<html><body><p>Ordinary email body.</p><img src="#{reference}"></body></html>)
          end
          ids.each_with_index do |cid, index|
            mime.add_part(Mail::Part.new do
              content_type 'image/png'
              content_disposition %(inline; filename="image#{index}.png")
              content_id "<#{cid}>"
              body File.binread(Rails.root.join('spec/assets/avatar.png'))
            end)
          end
          Mail.read_from_string(mime.encoded)
        end

        it 'uses the exact referenced blob and retains every unreferenced image', :aggregate_failures do
          expect(mail.attachments.map(&:cid)).to eq(ids)
          captured = nil
          allow(processed_mail).to receive(:attachments).and_wrap_original do |original, *args|
            captured = original.call(*args)
          end

          helper_instance.send(:add_attachments_to_message)

          message = conversation.messages.first.reload
          blobs = captured.to_h { |attachment| [attachment[:original].cid, attachment[:blob]] }
          html = message.content_attributes.dig('email', 'html_content', 'full')
          selected = 'photo@sender.test2'
          expect(Nokogiri::HTML.fragment(html).at_css('img')['src']).to eq(Rails.application.routes.url_helpers.url_for(blobs.fetch(selected)))
          expect(message.attachments.map { |attachment| attachment.file.blob_id }).to eq(
            (ids - [selected]).map { |cid| blobs.fetch(cid).id }
          )
        end
      end
    end

    context 'when an inline-marked image CID is not referenced in the HTML body' do
      let(:mail) do
        text_part = Mail::Part.new do
          body 'This is a plain text version of the message.'
        end
        html_part = Mail::Part.new do
          content_type 'text/html; charset=UTF-8'
          body '<html><body><p>Apple inline attachment</p><attachment id="image001.jpg@test"></attachment></body></html>'
        end
        inline_image_part = Mail::Part.new do
          content_type 'image/png'
          content_disposition 'inline; filename="image001.png"'
          content_id '<image001.jpg@test>'
          body File.binread(Rails.root.join('spec/assets/avatar.png'))
        end

        message = Mail.new
        message.from = 'Sender <sender@example.com>'
        message.to = 'Inbox <inbox@example.com>'
        message.subject = 'Inline image not referenced'
        message.message_id = '<unreferenced-inline-image@example.com>'
        message.text_part = text_part
        message.html_part = html_part
        message.add_part(inline_image_part)
        message
      end

      it 'processes the image as a regular attachment' do
        helper_instance.send(:add_attachments_to_message)

        message = conversation.messages[0]

        expect(message.attachments.count).to eq(1)
        expect(message.attachments.first.file_type).to eq('image')
        expect(message.content_attributes[:email][:html_content][:full]).to include('<attachment id="image001.jpg@test">')
      end
    end
  end
end
