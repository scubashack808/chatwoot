require 'rails_helper'

RSpec.describe Conversations::ReopenSnoozedConversationsJob do
  around do |example|
    freeze_time { example.run }
  end

  it 'enqueues the job' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class)
      .on_queue('low')
  end

  [4.days, 5.minutes, 0.seconds].each do |age|
    it "reopens a finite snooze #{age} seconds overdue only once" do
      conversation = create(:conversation, status: :snoozed, snoozed_until: age.ago)

      described_class.perform_now

      expect(conversation.reload.status).to eq 'open'
      expect(conversation.snoozed_until).to be_nil
      attributes = conversation.attributes
      travel 1.minute
      described_class.perform_now
      expect(conversation.reload.attributes).to eq attributes
    end
  end

  it 'leaves future and indefinite snoozes and other statuses unchanged' do
    future = create(:conversation, status: :snoozed, snoozed_until: 1.day.from_now)
    indefinite = create(:conversation, status: :snoozed)
    resolved = create(:conversation, status: :resolved)
    conversations = [future, indefinite, resolved]
    attributes = conversations.map(&:attributes)

    described_class.perform_now

    expect(conversations.map { |conversation| conversation.reload.attributes }).to eq attributes
  end

  it 'recovers overdue conversations across batch boundaries' do
    inbox = create(:inbox, enable_auto_assignment: false)
    conversations = create_list(:conversation, 101, account: inbox.account, inbox: inbox, status: :snoozed, snoozed_until: 4.days.ago)

    described_class.perform_now

    expect(Conversation.where(id: conversations.map(&:id)).where(status: :open, snoozed_until: nil).count).to eq 101
  end
end
