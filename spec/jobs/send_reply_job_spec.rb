require 'rails_helper'

RSpec.describe SendReplyJob do
  subject(:job) { described_class.perform_later(message) }

  let(:message) { create(:message) }

  it 'enqueues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(message)
      .on_queue('high')
  end

  context 'when delivering an Instagram text reply' do
    let(:channel) { create(:channel_instagram) }
    let(:conversation) { create(:conversation, inbox: channel.inbox, account: channel.account) }
    let(:message) do
      create(:message, conversation: conversation, inbox: channel.inbox, account: channel.account,
                       message_type: :outgoing, private: false, content: 'Synthetic Instagram reply')
    end
    let(:endpoint) { %r{https://graph.instagram.com/.*/#{channel.instagram_id}/messages} }

    before do
      allow(ChatwootExceptionTracker).to receive(:new).and_return(instance_double(ChatwootExceptionTracker, capture_exception: nil))
    end

    it 'persists a retryable failure when the connection is refused before sending' do
      request = stub_request(:post, endpoint).to_raise(Errno::ECONNREFUSED)

      expect { described_class.perform_now(message.id) }.not_to raise_error

      expect(request).to have_been_requested.once
      expect(message.reload.status).to eq('failed')
      expect(message.source_id).to be_nil
      expect(message.external_error).to eq('Instagram connection refused before sending. Please retry.')
      expect(message.content).to eq('Synthetic Instagram reply')
      expect(ChatwootExceptionTracker).to have_received(:new).with(instance_of(Errno::ECONNREFUSED), anything)
    end

    it 'stores the provider ID after a successful send' do
      stub_request(:post, endpoint).to_return(status: 200, body: { message_id: 'synthetic-instagram-id' }.to_json,
                                              headers: { 'Content-Type' => 'application/json' })

      described_class.perform_now(message.id)

      expect(message.reload.status).to eq('sent')
      expect(message.source_id).to eq('synthetic-instagram-id')
      expect(message.external_error).to be_blank
    end

    it 'retains failure handling for an HTTP rejection' do
      stub_request(:post, endpoint).to_return(status: 400, body: { error: { code: 100, message: 'Synthetic rejection' } }.to_json,
                                              headers: { 'Content-Type' => 'application/json' })

      described_class.perform_now(message.id)

      expect(message.reload.status).to eq('failed')
      expect(message.source_id).to be_nil
      expect(message.external_error).to eq('100 - Synthetic rejection')
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
