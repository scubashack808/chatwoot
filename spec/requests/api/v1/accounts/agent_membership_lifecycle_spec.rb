require 'rails_helper'

RSpec.describe 'Committed agent membership lifecycle', type: :request do
  self.use_transactional_tests = false

  let!(:account) { create(:account) }
  let!(:retained_account) { create(:account) }
  let!(:administrator) { create(:user, account: account, role: :administrator) }
  let!(:agent) { create(:user, account: account) }
  let!(:retained_membership) { create(:account_user, account: retained_account, user: agent) }

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  after do
    team_ids = Team.where(account: [account, retained_account]).pluck(:id)
    conversation_ids = Conversation.where(account: [account, retained_account]).pluck(:id)
    clear_enqueued_jobs
    perform_enqueued_jobs(only: ActiveRecord::DestroyAssociationAsyncJob) do
      [account, retained_account].each { |owned_account| owned_account.contacts.destroy_all }
      [account, retained_account].each(&:destroy!)
      [administrator, agent].each(&:destroy!)
    end
    Audited::Audit.where(associated_type: 'Account', associated_id: [account.id, retained_account.id]).delete_all
    Audited::Audit.where(auditable_type: 'User', auditable_id: [administrator.id, agent.id]).delete_all
    Audited::Audit.where(auditable_type: 'Team', auditable_id: team_ids).delete_all
    Audited::Audit.where(auditable_type: 'Conversation', auditable_id: conversation_ids).delete_all
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    Current.reset
  end

  [[false, 2], [true, 0], [true, 2]].each do |cleanup_first, repeat_deliveries|
    it "preserves re-addition with cleanup_first=#{cleanup_first} and #{repeat_deliveries} delayed deliveries", :aggregate_failures do
      expect(agent).to be_confirmed
      expect([account.saml_enabled?, retained_account.saml_enabled?]).to eq([false, false]) if ChatwootApp.enterprise?
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      original_setting = agent.notification_settings.find_by!(account: account)
      retained_setting = agent.notification_settings.find_by!(account: retained_account)
      old_inbox = create(:inbox, account: account, enable_auto_assignment: false)
      old_team = create(:team, account: account, allow_auto_assign: false)
      old_inbox_member = create(:inbox_member, inbox: old_inbox, user: agent)
      old_team_member = create(:team_member, team: old_team, user: agent)
      old_conversation = create(:conversation, account: account, inbox: old_inbox, assignee: agent)

      delete "/api/v1/accounts/#{account.id}/agents/#{agent.id}", headers: administrator.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      expect(AccountUser.exists?(account: account, user: agent)).to be(false)
      expect(NotificationSetting.exists?(original_setting.id)).to be(true)
      entry = enqueued_jobs.find { |job| job[:job] == Agents::DestroyJob }
      expect(entry).to be_present
      cleanup_args = entry[:args]
      Agents::DestroyJob.perform_now(*ActiveJob::Arguments.deserialize(cleanup_args)) if cleanup_first

      post "/api/v1/accounts/#{account.id}/agents", headers: administrator.create_new_auth_token,
                                                    params: { agent: { email: agent.email, name: agent.name, role: 'agent' } }, as: :json

      expect(response).to have_http_status(:success)
      expect(AccountUser.where(account: account, user: agent).count).to eq(1)
      expect(NotificationSetting.where(account: account, user: agent).count).to eq(1)
      expect(NotificationSetting.exists?(original_setting.id)).to be(false)
      expect(InboxMember.exists?(old_inbox_member.id)).to be(false)
      expect(TeamMember.exists?(old_team_member.id)).to be(false)
      expect(old_conversation.reload.assignee_id).to be_nil

      new_inbox = create(:inbox, account: account, enable_auto_assignment: false)
      new_team = create(:team, account: account, allow_auto_assign: false)
      new_inbox_member = create(:inbox_member, inbox: new_inbox, user: agent)
      new_team_member = create(:team_member, team: new_team, user: agent)
      new_conversation = create(:conversation, account: account, inbox: new_inbox, assignee: agent)
      new_setting = agent.notification_settings.find_by!(account: account)

      repeat_deliveries.times { Agents::DestroyJob.perform_now(*ActiveJob::Arguments.deserialize(cleanup_args)) }

      expect(AccountUser.where(account: account, user: agent).count).to eq(1)
      expect(NotificationSetting.where(account: account, user: agent).pluck(:id)).to eq([new_setting.id])
      expect(InboxMember.exists?(new_inbox_member.id)).to be(true)
      expect(TeamMember.exists?(new_team_member.id)).to be(true)
      expect(new_conversation.reload.assignee_id).to eq(agent.id)
      expect(AccountUser.exists?(retained_membership.id)).to be(true)
      expect(NotificationSetting.exists?(retained_setting.id)).to be(true)

      patch "/api/v1/accounts/#{account.id}/notification_settings",
            headers: agent.create_new_auth_token,
            params: { notification_settings: { selected_email_flags: ['email_conversation_assignment'],
                                               selected_push_flags: ['push_conversation_assignment'] } }, as: :json

      expect(response).to have_http_status(:success)
      expect(new_setting.reload.selected_email_flags).to eq([:email_conversation_assignment])
      expect(new_setting.selected_push_flags).to eq([:push_conversation_assignment])
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
    end
  end
end
