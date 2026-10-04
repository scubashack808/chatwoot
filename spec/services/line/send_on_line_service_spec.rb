require 'rails_helper'

describe Line::SendOnLineService do
  describe '#perform' do
    let(:line_client) { double }
    let(:line_channel) { create(:channel_line) }
    let(:message) do
      create(:message, message_type: :outgoing, content: 'test',
                       conversation: create(:conversation, inbox: line_channel.inbox))
    end

    before do
      allow(Line::Bot::Client).to receive(:new).and_return(line_client)
    end

    context 'when message send' do
      it 'calls @channel.client.push_message' do
        allow(line_client).to receive(:push_message)
        expect(line_client).to receive(:push_message)
        described_class.new(message: message).perform
      end
    end

    context 'when message send fails without details' do
      let(:error_response) do
        {
          'message' => 'The request was invalid'
        }.to_json
      end

      before do
        allow(line_client).to receive(:push_message).and_return(OpenStruct.new(code: '400', body: error_response))
      end

      it 'updates the message status to failed' do
        described_class.new(message: message).perform
        message.reload
        expect(message.status).to eq('failed')
      end

      it 'updates the external error without details' do
        described_class.new(message: message).perform
        message.reload
        expect(message.external_error).to eq('The request was invalid')
      end
    end

    context 'when message send fails with details' do
      let(:error_response) do
        {
          'message' => 'The request was invalid',
          'details' => [
            {
              'property' => 'messages[0].text',
              'message' => 'May not be empty'
            }
          ]
        }.to_json
      end

      before do
        allow(line_client).to receive(:push_message).and_return(OpenStruct.new(code: '400', body: error_response))
      end

      it 'updates the message status to failed' do
        described_class.new(message: message).perform
        message.reload
        expect(message.status).to eq('failed')
      end

      it 'updates the external error with details' do
        described_class.new(message: message).perform
        message.reload
        expect(message.external_error).to eq('The request was invalid, messages[0].text: May not be empty')
      end
    end

    context 'when message send succeeds' do
      let(:success_response) do
        {
          'message' => 'ok'
        }.to_json
      end

      before do
        allow(line_client).to receive(:push_message).and_return(OpenStruct.new(code: '200', body: success_response))
      end

      it 'updates the message status to delivered' do
        described_class.new(message: message).perform
        message.reload
        expect(message.status).to eq('delivered')
      end
    end

    context 'with message input_select' do
      let(:success_response) do
        {
          'message' => 'ok'
        }.to_json
      end

      let(:expect_message) do
        {
          type: 'flex',
          altText: 'test',
          contents: {
            type: 'bubble',
            body: {
              type: 'box',
              layout: 'vertical',
              contents: [
                {
                  type: 'text',
                  text: 'test',
                  wrap: true
                },
                {
                  type: 'button',
                  style: 'link',
                  height: 'sm',
                  action: {
                    type: 'message',
                    label: 'text 1',
                    text: 'value 1'
                  }
                },
                {
                  type: 'button',
                  style: 'link',
                  height: 'sm',
                  action: {
                    type: 'message',
                    label: 'text 2',
                    text: 'value 2'
                  }
                }
              ]
            }
          }
        }
      end

      it 'sends the message with input_select' do
        message = create(
          :message, message_type: :outgoing, content: 'test', content_type: 'input_select',
                    content_attributes: { 'items' => [{ 'title' => 'text 1', 'value' => 'value 1' }, { 'title' => 'text 2', 'value' => 'value 2' }] },
                    conversation: create(:conversation, inbox: line_channel.inbox)
        )

        expect(line_client).to receive(:push_message).with(
          message.conversation.contact_inbox.source_id,
          expect_message
        ).and_return(OpenStruct.new(code: '200', body: success_response))

        described_class.new(message: message).perform
      end
    end

    context 'with message attachments' do
      it 'sends the message with text and attachments' do
        attachment = message.attachments.new(account_id: message.account_id, file_type: :image)
        attachment.file.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
        attachment.save!
        expected_original_url_regex = %r{rails/active_storage/blobs/redirect/[a-zA-Z0-9=_\-+]+/avatar\.png}
        expected_preview_url_regex = %r{rails/active_storage/representations/redirect/[a-zA-Z0-9=_\-+]+/[a-zA-Z0-9=_\-+]+/avatar\.png}

        expect(line_client).to receive(:push_message).with(
          message.conversation.contact_inbox.source_id,
          [
            { type: 'text', text: message.content },
            {
              type: 'image',
              originalContentUrl: match(expected_original_url_regex),
              previewImageUrl: match(expected_preview_url_regex)
            }
          ]
        )

        described_class.new(message: message).perform
      end

      it 'sends the message with attachments only' do
        attachment = message.attachments.new(account_id: message.account_id, file_type: :image)
        attachment.file.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
        attachment.save!
        message.update!(content: nil)
        expected_original_url_regex = %r{rails/active_storage/blobs/redirect/[a-zA-Z0-9=_\-+]+/avatar\.png}
        expected_preview_url_regex = %r{rails/active_storage/representations/redirect/[a-zA-Z0-9=_\-+]+/[a-zA-Z0-9=_\-+]+/avatar\.png}

        expect(line_client).to receive(:push_message).with(
          message.conversation.contact_inbox.source_id,
          [
            {
              type: 'image',
              originalContentUrl: match(expected_original_url_regex),
              previewImageUrl: match(expected_preview_url_regex)
            }
          ]
        )

        described_class.new(message: message).perform
      end

      it 'sends the message with text only' do
        message.attachments.destroy_all
        expect(line_client).to receive(:push_message).with(
          message.conversation.contact_inbox.source_id,
          { type: 'text', text: message.content }
        )

        described_class.new(message: message).perform
      end
    end

    context 'with the LINE text length limit' do
      let(:limit_error) { I18n.t('errors.line.text_too_long', limit: 5000) }

      def utf16_units(text)
        text.encode('UTF-16LE').bytesize / 2
      end

      it 'sends exactly 5,000 characters as one unchanged text object' do
        message.update!(content: 'a' * 5000)
        expect(line_client).to receive(:push_message).with(
          message.conversation.contact_inbox.source_id,
          { type: 'text', text: 'a' * 5000 }
        )

        described_class.new(message: message).perform
      end

      [5001, 6000].each do |length|
        it "marks #{length} characters as failed without calling LINE" do
          message.update!(content: 'a' * length)
          expect(line_client).not_to receive(:push_message)

          described_class.new(message: message).perform

          expect(message.reload.status).to eq('failed')
          expect(message.external_error).to eq(limit_error)
          expect(message.content).to eq('a' * length)
        end
      end

      it 'counts UTF-16 code units, so 2,500 emoji are allowed and one more character is not' do
        message.update!(content: '😀' * 2500)
        expect(line_client).to receive(:push_message).once

        described_class.new(message: message).perform

        over_limit = create(:message, message_type: :outgoing, content: "#{'😀' * 2500}a", conversation: message.conversation)
        expect(over_limit.content.length).to eq(2501)

        described_class.new(message: over_limit).perform

        expect(over_limit.reload.status).to eq('failed')
        expect(over_limit.external_error).to eq(limit_error)
      end

      it 'measures the rendered text that would be sent, not the raw draft' do
        prefix = 'Hello **bold** and _italic_ '
        message.update!(content: "#{prefix}#{'a' * 4900}")
        padding = 5000 - utf16_units(message.outgoing_content)
        message.update!(content: "#{prefix}#{'a' * (4900 + padding)}")
        expect(utf16_units(message.outgoing_content)).to eq(5000)
        expect(message.outgoing_content.length).not_to eq(message.content.length)
        expect(line_client).to receive(:push_message).once

        described_class.new(message: message).perform

        over_limit = create(:message, message_type: :outgoing, content: "#{message.content}a", conversation: message.conversation)
        expect(utf16_units(over_limit.outgoing_content)).to eq(5001)

        described_class.new(message: over_limit).perform

        expect(over_limit.reload.status).to eq('failed')
      end

      it 'sends nothing when long text has an image attachment' do
        message.update!(content: 'a' * 5001)
        attachment = message.attachments.new(account_id: message.account_id, file_type: :image)
        attachment.file.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
        attachment.save!
        expect(line_client).not_to receive(:push_message)

        described_class.new(message: message).perform

        expect(message.reload.status).to eq('failed')
        expect(message.external_error).to eq(limit_error)
      end
    end
  end
end
