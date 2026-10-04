require 'rails_helper'

RSpec.describe SendReplyJob do
  subject(:job) { described_class.perform_later(message) }

  let(:message) { create(:message) }

  it 'enqueues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(message)
      .on_queue('high')
  end

  context 'when delivering Telegram attachments through the real service' do
    let(:channel) { create(:channel_telegram) }
    let(:conversation) do
      create(:conversation, account: channel.account, inbox: channel.inbox,
                            additional_attributes: { chat_id: '1001', business_connection_id: 'business123' })
    end
    let(:reply_target) { create(:message, account: channel.account, conversation: conversation, message_type: :incoming, source_id: '42') }
    let(:message) do
      create(:message, account: channel.account, conversation: conversation, message_type: :outgoing,
                       content: nil, content_attributes: { in_reply_to: reply_target.id })
    end
    let(:telegram_api_url) { channel.telegram_api_url }

    [[:image, 'photo', 'sendPhoto', 'sample.png', 'image/png'],
     [:audio, 'audio', 'sendAudio', 'sample.mp3', 'audio/mpeg']].each do |file_type, parameter, endpoint, filename, content_type|
      context "with one #{file_type}" do
        before do
          attachment = message.attachments.new(account_id: message.account_id, file_type: file_type)
          attachment.file.attach(io: Rails.root.join("spec/assets/#{filename}").open, filename: filename, content_type: content_type)
          message.save!
        end

        it 'sends text separately and a singleton with reply and business context, persisting the attachment ID' do
          message.update!(content: 'Attached media')
          text_request = stub_request(:post, "#{telegram_api_url}/sendMessage")
                         .with(body: hash_including('chat_id' => '1001', 'text' => 'Attached media'))
                         .to_return(status: 200, body: { ok: true, result: { message_id: 500 } }.to_json,
                                    headers: { 'Content-Type' => 'application/json' })
          request = stub_request(:post, "#{telegram_api_url}/#{endpoint}")
                    .with do |req|
            body = URI.decode_www_form(req.body).to_h
            expect(body[parameter]).to be_present
            expect(body).to include('chat_id' => '1001', 'business_connection_id' => 'business123')
            expect(JSON.parse(body.fetch('reply_parameters'))).to eq('message_id' => 42)
            expect(body.keys).not_to include('caption', 'media')
          end.to_return(status: 200, body: { ok: true, result: { message_id: 501 } }.to_json,
                        headers: { 'Content-Type' => 'application/json' })

          described_class.perform_now(message.id)

          expect(request).to have_been_requested.once
          expect(text_request).to have_been_requested.once
          expect(message.reload.source_id).to eq('501')
        end

        it 'does not send a private note' do
          message.update!(private: true)

          described_class.perform_now(message.id)

          expect(a_request(:post, /api.telegram.org/)).not_to have_been_made
          expect(message.reload.source_id).to be_nil
        end

        it 'does not resend a message with a source ID' do
          message.update!(source_id: 'existing')

          described_class.perform_now(message.id)

          expect(a_request(:post, /api.telegram.org/)).not_to have_been_made
          expect(message.reload.source_id).to eq('existing')
        end
      end
    end

    context 'with two images and text' do
      before do
        2.times do
          attachment = message.attachments.new(account_id: message.account_id, file_type: :image)
          attachment.file.attach(io: Rails.root.join('spec/assets/sample.png').open, filename: 'sample.png', content_type: 'image/png')
        end
        message.update!(content: 'Two photos')
      end

      it 'keeps text separate from the album and persists the album response message ID' do
        text_request = stub_request(:post, "#{telegram_api_url}/sendMessage")
                       .with(body: hash_including('chat_id' => '1001', 'text' => 'Two photos'))
                       .to_return(status: 200, body: { ok: true, result: { message_id: 500 } }.to_json,
                                  headers: { 'Content-Type' => 'application/json' })
        album_request = stub_request(:post, "#{telegram_api_url}/sendMediaGroup")
                        .with do |req|
          body = URI.decode_www_form(req.body).to_h
          expect(body).to include('chat_id' => '1001', 'business_connection_id' => 'business123', 'reply_to_message_id' => '42')
          media = JSON.parse(body.fetch('media'))
          expect(media).to match([{ 'type' => 'photo', 'media' => be_present }, { 'type' => 'photo', 'media' => be_present }])
        end.to_return(status: 200, body: { ok: true, result: [{ message_id: 501 }, { message_id: 502 }] }.to_json,
                      headers: { 'Content-Type' => 'application/json' })

        described_class.perform_now(message.id)

        expect(text_request).to have_been_requested.once
        expect(album_request).to have_been_requested.once
        expect(a_request(:post, "#{telegram_api_url}/sendPhoto")).not_to have_been_made
        expect(message.reload.source_id).to eq('501')
      end
    end
  end

  context 'when the job is triggered on a new message' do
    let(:process_service) { double }

    before do
      allow(process_service).to receive(:perform)
    end

    def expect_mapped_service_to_perform(message, service_class_name)
      channel_name = message.conversation.inbox.channel.class.name
      service_class = described_class::CHANNEL_SERVICES.fetch(channel_name)

      expect(service_class.name).to eq(service_class_name)
      expect(service_class).to receive(:new).with(message: message).and_return(process_service)
      expect(process_service).to receive(:perform)

      described_class.perform_now(message.id)
    end

    it 'calls Facebook::SendOnFacebookService when its facebook message' do
      stub_request(:post, /graph.facebook.com/)
      facebook_channel = create(:channel_facebook_page)
      facebook_inbox = create(:inbox, channel: facebook_channel)
      message = create(:message, conversation: create(:conversation, inbox: facebook_inbox))
      allow(Facebook::SendOnFacebookService).to receive(:new).with(message: message).and_return(process_service)
      expect(Facebook::SendOnFacebookService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::Twitter::SendOnTwitterService when its twitter message' do
      twitter_channel = create(:channel_twitter_profile)
      twitter_inbox = create(:inbox, channel: twitter_channel)
      message = create(:message, conversation: create(:conversation, inbox: twitter_inbox))
      expect_mapped_service_to_perform(message, 'Twitter::SendOnTwitterService')
    end

    it 'calls ::Twilio::SendOnTwilioService when its twilio message' do
      twilio_channel = create(:channel_twilio_sms)
      message = create(:message, conversation: create(:conversation, inbox: twilio_channel.inbox))
      expect_mapped_service_to_perform(message, 'Twilio::SendOnTwilioService')
    end

    it 'calls ::Telegram::SendOnTelegramService when its telegram message' do
      telegram_channel = create(:channel_telegram)
      message = create(:message, conversation: create(:conversation, inbox: telegram_channel.inbox))
      expect_mapped_service_to_perform(message, 'Telegram::SendOnTelegramService')
    end

    it 'calls ::Line:SendOnLineService when its line message' do
      line_channel = create(:channel_line)
      message = create(:message, conversation: create(:conversation, inbox: line_channel.inbox))
      expect_mapped_service_to_perform(message, 'Line::SendOnLineService')
    end

    it 'calls ::Whatsapp:SendOnWhatsappService when its whatsapp message' do
      stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook')
      whatsapp_channel = create(:channel_whatsapp, sync_templates: false)
      message = create(:message, conversation: create(:conversation, inbox: whatsapp_channel.inbox))
      expect_mapped_service_to_perform(message, 'Whatsapp::SendOnWhatsappService')
    end

    it 'calls ::Sms::SendOnSmsService when its sms message' do
      sms_channel = create(:channel_sms)
      message = create(:message, conversation: create(:conversation, inbox: sms_channel.inbox))
      expect_mapped_service_to_perform(message, 'Sms::SendOnSmsService')
    end

    it 'calls ::Instagram::Direct::SendOnInstagramService when its instagram message' do
      instagram_channel = create(:channel_instagram)
      message = create(:message, conversation: create(:conversation, inbox: instagram_channel.inbox))
      expect_mapped_service_to_perform(message, 'Instagram::SendOnInstagramService')
    end

    it 'calls ::Instagram::Messenger::SendOnInstagramService when its an instagram_direct_message from facebook channel' do
      stub_request(:post, /graph.facebook.com/)
      facebook_channel = create(:channel_facebook_page)
      facebook_inbox = create(:inbox, channel: facebook_channel)
      conversation = create(:conversation,
                            inbox: facebook_inbox,
                            additional_attributes: { 'type' => 'instagram_direct_message' })
      message = create(:message, conversation: conversation)

      allow(Instagram::Messenger::SendOnInstagramService).to receive(:new).with(message: message).and_return(process_service)
      expect(Instagram::Messenger::SendOnInstagramService).to receive(:new).with(message: message)
      expect(process_service).to receive(:perform)
      described_class.perform_now(message.id)
    end

    it 'calls ::Email::SendOnEmailService when its email message' do
      email_channel = create(:channel_email)
      message = create(:message, conversation: create(:conversation, inbox: email_channel.inbox))
      expect_mapped_service_to_perform(message, 'Email::SendOnEmailService')
    end

    it 'calls ::Messages::SendEmailNotificationService when its webwidget message' do
      webwidget_channel = create(:channel_widget)
      message = create(:message, conversation: create(:conversation, inbox: webwidget_channel.inbox))
      expect_mapped_service_to_perform(message, 'Messages::SendEmailNotificationService')
    end

    it 'calls ::Messages::SendEmailNotificationService when its api channel message' do
      api_channel = create(:channel_api)
      message = create(:message, conversation: create(:conversation, inbox: api_channel.inbox))
      expect_mapped_service_to_perform(message, 'Messages::SendEmailNotificationService')
    end

    it 'calls ::Tiktok::SendOnTiktokService when its tiktok message' do
      tiktok_channel = create(:channel_tiktok)
      message = create(:message, conversation: create(:conversation, inbox: tiktok_channel.inbox))
      expect_mapped_service_to_perform(message, 'Tiktok::SendOnTiktokService')
    end
  end
end
