require 'rails_helper'

describe Telegram::UpdateMessageService do
  let!(:telegram_channel) { create(:channel_telegram) }
  let(:common_message_params) do
    {
      'from': {
        'id': 123,
        'username': 'sojan'
      },
      'chat': {
        'id': 789,
        'type': 'private'
      },
      'date': Time.now.to_i,
      'edit_date': Time.now.to_i
    }
  end

  let(:text_update_params) do
    {
      'update_id': 1,
      'edited_message': common_message_params.merge(
        'message_id': 48,
        'text': 'updated message'
      )
    }
  end

  let(:caption_update_params) do
    {
      'update_id': 2,
      'edited_message': common_message_params.merge(
        'message_id': 49,
        'caption': 'updated caption'
      )
    }
  end

  describe '#perform' do
    context 'when valid update message params' do
      let(:contact_inbox) { create(:contact_inbox, inbox: telegram_channel.inbox, source_id: common_message_params[:chat][:id]) }
      let(:conversation) do
        create(:conversation, account: telegram_channel.account, inbox: telegram_channel.inbox,
                              contact: contact_inbox.contact, contact_inbox: contact_inbox)
      end

      it 'updates the message text when text is present' do
        message = create(:message, conversation: conversation, source_id: text_update_params[:edited_message][:message_id])
        described_class.new(inbox: telegram_channel.inbox, params: text_update_params.with_indifferent_access).perform
        expect(message.reload.content).to eq('updated message')
      end

      it 'updates the message caption when caption is present' do
        message = create(:message, conversation: conversation, source_id: caption_update_params[:edited_message][:message_id])
        described_class.new(inbox: telegram_channel.inbox, params: caption_update_params.with_indifferent_access).perform
        expect(message.reload.content).to eq('updated caption')
      end

      context 'when business message' do
        let(:text_update_params) do
          {
            'update_id': 1,
            'edited_business_message': common_message_params.merge(
              'message_id': 48,
              'text': 'updated message'
            )
          }
        end

        it 'updates the message text when text is present' do
          message = create(:message, conversation: conversation, source_id: text_update_params[:edited_business_message][:message_id])
          described_class.new(inbox: telegram_channel.inbox, params: text_update_params.with_indifferent_access).perform
          expect(message.reload.content).to eq('updated message')
        end
      end
    end

    collision_scopes = %i[same_inbox foreign_account]
    %i[edited_message edited_business_message].each do |event_key|
      context "when #{event_key} targets conversation history" do
        let(:inbox) { telegram_channel.inbox }
        let(:account) { telegram_channel.account }
        let!(:contact_inbox) { create(:contact_inbox, inbox: inbox, contact: create(:contact, account: account), source_id: '1001') }
        let!(:older) do
          create(:conversation, account: account, inbox: inbox, contact: contact_inbox.contact, contact_inbox: contact_inbox, status: :resolved)
        end
        let!(:original) { create(:message, account: account, inbox: inbox, conversation: older, source_id: '101', content: 'Original time') }
        let!(:newer) { create(:conversation, account: account, inbox: inbox, contact: contact_inbox.contact, contact_inbox: contact_inbox) }
        let!(:new_topic) { create(:message, account: account, inbox: inbox, conversation: newer, source_id: '102', content: 'New topic') }
        let(:edit) { { message_id: 101, chat: { id: 1001, type: 'private' }, text: 'Corrected time' } }
        let(:service) { described_class.new(inbox: inbox, params: { event_key => edit }.with_indifferent_access) }

        before do
          inbox.update!(lock_to_single_conversation: false)
          older.resolved!
        end

        it 'updates text in the older conversation without changing the newer message' do
          service.perform

          expect(original.reload.content).to eq('Corrected time')
          expect(new_topic.reload.content).to eq('New topic')
        end

        it 'updates a caption in the older conversation' do
          edit.delete(:text)
          edit[:caption] = 'Corrected caption'
          service.perform

          expect(original.reload.content).to eq('Corrected caption')
          expect(new_topic.reload.content).to eq('New topic')
        end

        it 'still updates the latest conversation' do
          edit[:message_id] = 102
          service.perform

          expect(new_topic.reload.content).to eq('Corrected time')
          expect(original.reload.content).to eq('Original time')
        end

        collision_scopes.each do |collision_scope|
          context "when a message ID collides in #{collision_scope}" do
            let!(:foreign_message) do
              other_inbox = collision_scope == :same_inbox ? inbox : create(:channel_telegram, bot_token: '987654321').inbox
              other_contact = create(:contact, account: other_inbox.account)
              other_link = create(:contact_inbox, inbox: other_inbox, contact: other_contact,
                                                  source_id: collision_scope == :same_inbox ? '2002' : '1001')
              other_conversation = create(:conversation, account: other_inbox.account, inbox: other_inbox,
                                                         contact: other_contact, contact_inbox: other_link)
              create(:message, account: other_inbox.account, inbox: other_inbox,
                               conversation: other_conversation, source_id: '101', content: 'Other chat')
            end

            it 'only updates the matching chat' do
              service.perform

              expect(original.reload.content).to eq('Corrected time')
              expect(foreign_message.reload.content).to eq('Other chat')
            end

            it 'warns and returns nil without creating records when the local target is absent' do
              original.destroy!
              expect(Rails.logger).to receive(:warn).with(
                "Telegram edit target not found: inbox_id=#{inbox.id} contact_inbox_id=#{contact_inbox.id} message_id=101"
              )
              expect(Rails.logger).not_to receive(:error)

              expect { expect(service.perform).to be_nil }.not_to(change { [Message.count, Conversation.count] })
              expect(foreign_message.reload.content).to eq('Other chat')
              expect(new_topic.reload.content).to eq('New topic')
            end
          end
        end
      end
    end

    context 'when invalid update message params' do
      it 'will not raise errors' do
        expect do
          described_class.new(inbox: telegram_channel.inbox, params: {}).perform
        end.not_to raise_error
      end
    end
  end
end
