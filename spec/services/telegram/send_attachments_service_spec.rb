require 'rails_helper'

RSpec.describe Telegram::SendAttachmentsService do
  describe '#perform' do
    let(:channel) { create(:channel_telegram) }
    let(:message) do
      build(:message, conversation: create(:conversation, inbox: channel.inbox, additional_attributes: { chat_id: 'chat123' }))
    end
    let(:service) { described_class.new(message: message) }
    let(:telegram_api_url) { channel.telegram_api_url }

    before do
      stub_request(:post, "#{telegram_api_url}/sendMediaGroup")
        .with { |request| (2..10).cover?(JSON.parse(URI.decode_www_form(request.body).to_h.fetch('media')).length) }
        .to_return(status: 200, body: { ok: true, result: [{ message_id: 'media' }] }.to_json, headers: { 'Content-Type' => 'application/json' })

      stub_request(:post, "#{telegram_api_url}/sendAudio")
        .with(body: hash_including('audio' => /.+/))
        .to_return(status: 200, body: { ok: true, result: { message_id: 'audio' } }.to_json, headers: { 'Content-Type' => 'application/json' })

      stub_request(:post, "#{telegram_api_url}/sendDocument")
        .to_return(status: 200, body: { ok: true, result: { message_id: 'document' } }.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'sends all types of attachments in seperate groups and returns the last successful message ID from the batch' do
      attach_files(message)
      result = service.perform
      expect(result).to eq('document')
      # videos and images are sent in a media group
      # singleton audio is sent individually
      expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup")).to have_been_made.once
      expect(a_request(:post, "#{telegram_api_url}/sendAudio")).to have_been_made.once
      expect(a_request(:post, "#{telegram_api_url}/sendDocument")).to have_been_made.once
    end

    context_options = [false, true]
    { image: ['photo', 'sample.png', 'image/png'], audio: ['audio', 'sample.mp3', 'audio/mpeg'],
      video: ['video', 'sample.mp4', 'video/mp4'] }.each do |file_type, (type, filename, content_type)|
      context "with one #{file_type}" do
        before do
          freeze_time
          attachment = message.attachments.new(account_id: message.account_id, file_type: file_type)
          attachment.file.attach(io: Rails.root.join("spec/assets/#{filename}").open, filename: filename, content_type: content_type)
          message.save!
        end

        context_options.each do |with_context|
          it "uses the singleton endpoint with context #{with_context}" do
            if with_context
              message.conversation.update!(additional_attributes: { chat_id: 'chat123', business_connection_id: 'business123' })
              reply_target = create(:message, conversation: message.conversation, source_id: '42')
              message.update!(content_attributes: { in_reply_to: reply_target.id })
            end
            request = stub_request(:post, "#{telegram_api_url}/send#{type.capitalize}").with do |req|
              body = URI.decode_www_form(req.body).to_h
              expected_body = { 'chat_id' => 'chat123', type => message.attachments.first.download_url }
              if with_context
                expected_body['business_connection_id'] = 'business123'
                expected_body['reply_parameters'] = { message_id: 42 }.to_json
              end
              expect(body).to eq(expected_body)
              true
            end.to_return(status: 200, body: { ok: true, result: { message_id: 'singleton' } }.to_json,
                          headers: { 'Content-Type' => 'application/json' })

            expect(service.perform).to eq('singleton')
            expect(request).to have_been_requested.once
            expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup")).not_to have_been_made
          end
        end
      end
    end

    context 'when all attachments are documents' do
      before do
        2.times { attach_file_to_message(message, 'file', 'sample.pdf', 'application/pdf') }
        message.save!
      end

      it 'sends documents individually and returns the message ID of the first successful document' do
        result = service.perform
        expect(result).to eq('document')
        expect(a_request(:post, "#{telegram_api_url}/sendDocument")).to have_been_made.times(2)
      end
    end

    context 'when this is business chat' do
      before do
        message.conversation.update!(additional_attributes: { 'business_connection_id' => 'eooW3KF5WB5HxTD7T826' })
      end

      it 'sends all types of attachments in seperate groups and returns the last successful message ID from the batch' do
        attach_files(message)
        service.perform
        expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup")
          .with { |req| req.body =~ /business_connection_id.+eooW3KF5WB5HxTD7T826/m })
          .to have_been_made.once
        expect(a_request(:post, "#{telegram_api_url}/sendAudio")
          .with(body: hash_including('business_connection_id' => 'eooW3KF5WB5HxTD7T826'))).to have_been_made.once

        expect(a_request(:post, "#{telegram_api_url}/sendDocument")
          .with { |req| req.body =~ /business_connection_id.+eooW3KF5WB5HxTD7T826/m })
          .to have_been_made.once
      end
    end

    context 'when all attachments are photo and video' do
      before do
        2.times { attach_file_to_message(message, 'image', 'sample.png', 'image/png') }
        attach_file_to_message(message, 'video', 'sample.mp4', 'video/mp4')
        message.save!
      end

      it 'sends in a single media group and returns the message ID' do
        result = service.perform
        expect(result).to eq('media')
        expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup")).to have_been_made.once
      end
    end

    context 'when all attachments are audio' do
      before do
        2.times { attach_file_to_message(message, 'audio', 'sample.mp3', 'audio/mpeg') }
        message.save!
      end

      it 'sends audio messages in single media group and returns the message ID' do
        result = service.perform
        expect(result).to eq('media')
        expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup")).to have_been_made.once
      end
    end

    context 'when all attachments are photos, videos, and audio' do
      before do
        attach_file_to_message(message, 'image', 'sample.png', 'image/png')
        attach_file_to_message(message, 'video', 'sample.mp4', 'video/mp4')
        attach_file_to_message(message, 'audio', 'sample.mp3', 'audio/mpeg')
        message.save!
      end

      it 'sends photos and videos in a media group and singleton audio individually' do
        result = service.perform
        expect(result).to eq('audio')
        expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup")).to have_been_made.once
        expect(a_request(:post, "#{telegram_api_url}/sendAudio")).to have_been_made.once
      end
    end

    context 'when media and audio groups each contain one attachment' do
      before do
        attach_file_to_message(message, 'image', 'sample.png', 'image/png')
        attach_file_to_message(message, 'audio', 'sample.mp3', 'audio/mpeg')
        attach_file_to_message(message, 'file', 'sample.pdf', 'application/pdf')
        message.save!
      end

      it 'sends both singleton endpoints and preserves the separate document path' do
        photo_request = stub_request(:post, "#{telegram_api_url}/sendPhoto")
                        .with(body: hash_including('photo' => /.+/))
                        .to_return(status: 200, body: { ok: true, result: { message_id: 'photo' } }.to_json,
                                   headers: { 'Content-Type' => 'application/json' })

        expect(service.perform).to eq('document')
        expect(photo_request).to have_been_requested.once
        expect(a_request(:post, "#{telegram_api_url}/sendAudio")).to have_been_made.once
        expect(a_request(:post, "#{telegram_api_url}/sendDocument")).to have_been_made.once
        expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup")).not_to have_been_made
      end

      it 'stops subsequent groups and preserves failure handling when the singleton fails' do
        stub_request(:post, "#{telegram_api_url}/sendPhoto")
          .to_return(status: 400, body: { ok: false, error_code: 400, description: 'Bad Request' }.to_json,
                     headers: { 'Content-Type' => 'application/json' })

        expect(service.perform).to be_nil
        expect(message.reload.status).to eq('failed')
        expect(message.content_attributes['external_error']).to include('Bad Request')
        expect(a_request(:post, "#{telegram_api_url}/sendAudio")).not_to have_been_made
        expect(a_request(:post, "#{telegram_api_url}/sendDocument")).not_to have_been_made
        expect(a_request(:post, "#{telegram_api_url}/sendMediaGroup")).not_to have_been_made
      end
    end

    context 'when an attachment fails to send' do
      before do
        stub_request(:post, "#{telegram_api_url}/sendDocument")
          .to_return(status: 500, body: { ok: false,
                                          description: 'Internal server error' }.to_json, headers: { 'Content-Type' => 'application/json' })
      end

      it 'logs an error, stops processing, and returns nil' do
        attach_files(message)
        expect(Rails.logger).to receive(:error).at_least(:once)
        result = service.perform
        expect(result).to be_nil
        expect(a_request(:post, "#{telegram_api_url}/sendDocument")).to have_been_made.once
      end
    end

    def attach_files(message)
      attach_file_to_message(message, 'file', 'sample.pdf', 'application/pdf')
      attach_file_to_message(message, 'image', 'sample.png', 'image/png')
      attach_file_to_message(message, 'video', 'sample.mp4', 'video/mp4')
      attach_file_to_message(message, 'audio', 'sample.mp3', 'audio/mpeg')
      message.save!
    end

    def attach_file_to_message(message, type, filename, content_type)
      attachment = message.attachments.new(account_id: message.account_id, file_type: type)
      attachment.file.attach(io: Rails.root.join("spec/assets/#{filename}").open, filename: filename, content_type: content_type)
    end
  end
end
