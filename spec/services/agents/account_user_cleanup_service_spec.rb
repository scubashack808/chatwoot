require 'rails_helper'
require 'timeout'

RSpec.describe Agents::AccountUserCleanupService do
  subject(:service) { described_class.new }

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  it 'does not clean up a current membership, even with a dirty account instance' do
    setting = user.notification_settings.find_by!(account: account)
    account.name = 'Unsaved account name'

    service.perform(account, user)

    expect(setting.reload).to be_persisted
    expect(account.name).to eq('Unsaved account name')
    expect(account).to be_changed
  end

  it 'cleans only the removed account and tolerates repeated delivery' do
    other_account = create(:account)
    create(:account_user, account: other_account, user: user)
    retained_setting = user.notification_settings.find_by!(account: other_account)
    account.account_users.find_by!(user: user).destroy!

    2.times { service.perform(account, user) }

    expect(user.notification_settings.where(account: account)).to be_empty
    expect(retained_setting.reload).to be_persisted
    expect(AccountUser.exists?(account: other_account, user: user)).to be(true)
  end

  context 'with committed concurrent membership changes' do
    self.use_transactional_tests = false

    let!(:account) { create(:account) }
    let!(:other_account) { create(:account) }
    let!(:user) { create(:user, account: account) }
    let!(:retained_membership) { create(:account_user, account: other_account, user: user) }
    let!(:team) { create(:team, account: account, allow_auto_assign: false) }
    let!(:old_member) { create(:team_member, team: team, user: user) }
    let!(:old_setting) { user.notification_settings.find_by!(account: account) }
    let(:threads) { [] }
    let(:release) { Queue.new }

    before do
      account.account_users.find_by!(user: user).destroy!
      clear_enqueued_jobs
    end

    after do
      release << true
      threads.each do |thread|
        thread.kill unless thread.join(10)
        thread.join
      end
      TeamMember.where(team_id: team.id).delete_all
      team.destroy!
      AccountUser.where(account_id: [account.id, other_account.id]).delete_all
      NotificationSetting.where(account_id: [account.id, other_account.id]).delete_all
      user.destroy!
      account.destroy!
      other_account.destroy!
      clear_enqueued_jobs
      Current.reset
    end

    def start_connection_thread(&)
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection(&)
      ensure
        Current.reset
      end
    end

    def wait_for_database_lock(holder_pid, waiter_pid)
      connection = ActiveRecord::Base.connection
      Timeout.timeout(10) do
        loop do
          blocked = connection.select_value("SELECT #{Integer(holder_pid)} = ANY(pg_blocking_pids(#{Integer(waiter_pid)}))")
          break if blocked

          Thread.pass
        end
      end
    end

    def hold_transaction(operation, acquired)
      start_connection_thread do |connection|
        Account.transaction do
          operation.call
          acquired << connection.select_value('SELECT pg_backend_pid()')
          Timeout.timeout(10) { release.pop }
        end
      end
    end

    def run_contending_operations(first, second)
      acquired = Queue.new
      waiting = Queue.new
      hold_transaction(first, acquired)
      first_pid = Timeout.timeout(10) { acquired.pop }
      start_connection_thread do |connection|
        waiting << connection.select_value('SELECT pg_backend_pid()')
        second.call
      end
      wait_for_database_lock(first_pid, Timeout.timeout(10) { waiting.pop })
      release << true
      threads.each do |thread|
        expect(thread.join(10)).to eq(thread)
        thread.value
      end
    end

    %i[cleanup creation].each do |first_operation|
      it "serializes #{first_operation} first through the outer transaction commit" do
        expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
        retained_setting = user.notification_settings.find_by!(account: other_account)
        payload = ActiveJob::Arguments.serialize([account, user])
        create_membership = lambda do
          AccountUser.create!(account: account, user: user)
          TeamMember.create!(team: team, user: user)
        end
        cleanup = -> { described_class.new.perform(account, user) }
        operations = first_operation == :cleanup ? [cleanup, create_membership] : [create_membership, cleanup]

        run_contending_operations(*operations)

        expect(AccountUser.where(account: account, user: user).count).to eq(1)
        expect(NotificationSetting.exists?(old_setting.id)).to be(false)
        expect(TeamMember.exists?(old_member.id)).to be(false)
        new_member = TeamMember.find_by!(team: team, user: user)
        2.times { Agents::DestroyJob.perform_now(*ActiveJob::Arguments.deserialize(payload)) }
        expect(new_member.reload).to be_persisted
        expect(NotificationSetting.where(account: account, user: user).count).to eq(1)
        expect([retained_membership.reload, retained_setting.reload]).to all(be_persisted)
      end
    end
  end
end
