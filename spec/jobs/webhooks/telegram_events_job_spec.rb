require 'rails_helper'

RSpec.describe Webhooks::TelegramEventsJob do
  subject(:job) { described_class.perform_later(params) }

  let!(:telegram_channel) { create(:channel_telegram) }
  let!(:params) { { :bot_token => telegram_channel.bot_token, 'telegram' => { test: 'test' } } }

  it 'enqueues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(params)
      .on_queue('default')
  end

  context 'when invalid params' do
    it 'returns nil when no bot_token' do
      expect(described_class.perform_now({})).to be_nil
    end

    it 'logs a warning when channel is not found' do
      expect(Rails.logger).to receive(:warn).with('Telegram event discarded: Channel not found for bot_token: invalid')
      described_class.perform_now({ bot_token: 'invalid' })
    end
  end

  context 'when valid params' do
    it 'calls Telegram::IncomingMessageService' do
      process_service = double
      allow(Telegram::IncomingMessageService).to receive(:new).and_return(process_service)
      allow(process_service).to receive(:perform)
      expect(Telegram::IncomingMessageService).to receive(:new).with(inbox: telegram_channel.inbox,
                                                                     params: params['telegram'].with_indifferent_access)
      expect(process_service).to receive(:perform)
      described_class.perform_now(params.with_indifferent_access)
    end

    it 'logs a warning and does not process events if account is suspended' do
      account = telegram_channel.account
      account.update!(status: :suspended)

      process_service = double
      allow(Telegram::IncomingMessageService).to receive(:new).and_return(process_service)
      allow(process_service).to receive(:perform)

      expect(Rails.logger).to receive(:warn).with("Telegram event discarded: Account #{account.id} is not active for channel #{telegram_channel.id}")
      expect(Telegram::IncomingMessageService).not_to receive(:new)
      described_class.perform_now(params.with_indifferent_access)
    end
  end

  %i[edited_message edited_business_message].each do |event_key|
    context "when #{event_key} targets an older conversation" do
      let(:inbox) { telegram_channel.inbox }
      let(:account) { telegram_channel.account }
      let(:contact) { create(:contact, account: account) }
      let(:contact_inbox) { create(:contact_inbox, inbox: inbox, contact: contact, source_id: '1001') }
      let!(:older) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :resolved) }
      let!(:original) { create(:message, account: account, inbox: inbox, conversation: older, source_id: '101', content: 'Original time') }
      let!(:newer) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :open) }
      let!(:new_topic) { create(:message, account: account, inbox: inbox, conversation: newer, source_id: '102', content: 'New topic') }
      let!(:params) do
        { bot_token: telegram_channel.bot_token,
          telegram: { event_key => { message_id: 101, chat: { id: 1001, type: 'private' }, text: 'Corrected time' } } }
      end

      it 'persists the edit without changing conversation statuses or the newer message' do
        inbox.update!(lock_to_single_conversation: false)
        older.resolved!

        expect { described_class.perform_now(params.with_indifferent_access) }.not_to(change { [Message.count, Conversation.count] })

        expect(original.reload.content).to eq('Corrected time')
        expect(new_topic.reload.content).to eq('New topic')
        expect(older.reload.status).to eq('resolved')
        expect(newer.reload.status).to eq('open')
      end
    end
  end

  context 'when update message params' do
    let!(:params) { { :bot_token => telegram_channel.bot_token, 'telegram' => { edited_message: 'test' } } }

    it 'calls Telegram::UpdateMessageService' do
      process_service = double
      allow(Telegram::UpdateMessageService).to receive(:new).and_return(process_service)
      allow(process_service).to receive(:perform)
      expect(Telegram::UpdateMessageService).to receive(:new).with(inbox: telegram_channel.inbox,
                                                                   params: params['telegram'].with_indifferent_access)
      expect(process_service).to receive(:perform)
      described_class.perform_now(params.with_indifferent_access)
    end
  end
end
