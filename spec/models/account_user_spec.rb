# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountUser do
  include ActiveJob::TestHelper

  let!(:account_user) { create(:account_user) }
  let!(:inbox) { create(:inbox, account: account_user.account) }

  describe 'notification_settings' do
    it 'gets created with the right default settings' do
      expect(account_user.user.notification_settings).not_to be_nil

      expect(account_user.user.notification_settings.first.email_conversation_creation?).to be(false)
      expect(account_user.user.notification_settings.first.email_conversation_assignment?).to be(true)
    end
  end

  describe 'membership lifecycle transactions' do
    it 'replaces stale settings and permissions when directly re-added' do
      account = account_user.account
      user = account_user.user
      old_setting = user.notification_settings.find_by!(account: account)
      create(:inbox_member, inbox: inbox, user: user)
      account_user.destroy!

      replacement = described_class.create!(account: account, user: user)

      expect(replacement).to be_persisted
      expect(NotificationSetting.exists?(old_setting.id)).to be(false)
      expect(user.notification_settings.where(account: account).count).to eq(1)
      expect(user.inbox_members.where(inbox: inbox)).to be_empty
    end

    it 'rolls back membership and restores stale resources when settings creation fails' do
      account = account_user.account
      user = account_user.user
      old_setting = user.notification_settings.find_by!(account: account)
      old_member = create(:inbox_member, inbox: inbox, user: user)
      account_user.destroy!
      replacement = described_class.new(account: account, user: user)
      setting = NotificationSetting.new(account: account, user: user)
      allow(user.notification_settings).to receive(:new).with(account_id: account.id).and_return(setting)
      allow(setting).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(setting))

      expect do
        described_class.transaction(requires_new: true) { replacement.save! }
      end.to raise_error(ActiveRecord::RecordInvalid)

      expect(described_class.exists?(account: account, user: user)).to be(false)
      expect(NotificationSetting.exists?(old_setting.id)).to be(true)
      expect(InboxMember.exists?(old_member.id)).to be(true)
    end

    it 'does not enqueue cleanup for a rolled-back destruction' do
      clear_enqueued_jobs

      described_class.transaction(requires_new: true) do
        account_user.destroy!
        raise ActiveRecord::Rollback
      end

      expect(account_user.reload).to be_persisted
      expect(Agents::DestroyJob).not_to have_been_enqueued
    end
  end

  describe 'permissions' do
    it 'returns the right permissions' do
      expect(account_user.permissions).to eq(['agent'])
    end

    it 'returns the right permissions for administrator' do
      account_user.administrator!
      expect(account_user.permissions).to eq(['administrator'])
    end
  end

  describe 'destroy call agent::destroy service' do
    it 'gets created with the right default settings' do
      create(:conversation, account: account_user.account, assignee: account_user.user, inbox: inbox)
      user = account_user.user

      expect(user.assigned_conversations.count).to eq(1)

      perform_enqueued_jobs do
        account_user.destroy!
      end

      expect(user.assigned_conversations.count).to eq(0)
    end
  end

  describe 'filtered unread count invalidation' do
    let(:account) { create(:account) }
    let(:user) { create(:user) }
    let(:invalidator) { instance_double(Conversations::UnreadCounts::FilteredCountInvalidator, user_visibility_changed!: true) }

    before do
      allow(Conversations::UnreadCounts::FilteredCountInvalidator).to receive(:new).and_return(invalidator)
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
    end

    it 'invalidates filtered counts when the user is added to an account' do
      create(:account_user, account: account, user: user)

      expect(invalidator).to have_received(:user_visibility_changed!).with(user_id: user.id)
    end

    it 'invalidates filtered counts when the user role changes' do
      account_user = create(:account_user, account: account, user: user)

      account_user.update!(role: :administrator)

      expect(invalidator).to have_received(:user_visibility_changed!).with(user_id: user.id).twice
      expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(
        'account.cache_invalidated',
        kind_of(Time),
        account: account,
        cache_keys: account.cache_keys
      )
    end

    it 'invalidates filtered counts when the user is removed from an account' do
      account_user = create(:account_user, account: account, user: user)

      account_user.destroy!

      expect(invalidator).to have_received(:user_visibility_changed!).with(user_id: user.id).twice
    end
  end
end
