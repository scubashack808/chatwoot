require 'rails_helper'

RSpec.describe Notification::ReopenSnoozedNotificationsJob do
  around do |example|
    freeze_time { example.run }
  end

  it 'enqueues the job' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class)
      .on_queue('low')
  end

  [4.days, 5.minutes, 0.seconds].each do |age|
    it "recovers a finite snooze #{age} seconds overdue and makes it visible only once" do
      deadline = age.ago
      notification = create(:notification, snoozed_until: deadline, read_at: 1.day.ago, meta: { 'existing' => 'value' })
      expect(NotificationFinder.new(notification.user, notification.account).notifications).not_to include(notification)

      described_class.perform_now

      expect(notification.reload).to have_attributes(snoozed_until: nil, read_at: nil, last_activity_at: Time.current)
      expect(Time.zone.parse(notification.meta['last_snoozed_at'])).to eq deadline
      expect(notification.meta['existing']).to eq 'value'
      expect(NotificationFinder.new(notification.user, notification.account).notifications).to include(notification)
      attributes = notification.attributes
      travel 1.minute
      described_class.perform_now
      expect(notification.reload.attributes).to eq attributes
    end
  end

  it 'leaves future snoozes and already unsnoozed notifications unchanged' do
    future = create(:notification, snoozed_until: 1.day.from_now)
    unsnoozed = create(:notification, read_at: 1.day.ago)
    attributes = [future.attributes, unsnoozed.attributes]

    described_class.perform_now

    expect([future.reload.attributes, unsnoozed.reload.attributes]).to eq attributes
    expect(NotificationFinder.new(future.user, future.account).notifications).not_to include(future)
  end

  it 'recovers overdue notifications across batch boundaries' do
    conversation = create(:conversation)
    user = create(:user, account: conversation.account)
    notifications = create_list(:notification, 101, account: conversation.account, user: user,
                                                    primary_actor: conversation, snoozed_until: 4.days.ago, read_at: 1.day.ago)

    described_class.perform_now

    expect(Notification.where(id: notifications.map(&:id)).where(snoozed_until: nil, read_at: nil).count).to eq 101
  end
end
