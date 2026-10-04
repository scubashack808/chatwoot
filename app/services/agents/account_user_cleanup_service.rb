class Agents::AccountUserCleanupService
  # pending_only limits cleanup to a removed membership whose deferred cleanup has not run yet.
  # Cleanup deletes the notification setting in the same transaction as the other resources,
  # so a remaining setting marks it as pending; a first-time membership never has one.
  def perform(account, user, pending_only: false)
    Account.find(account.id).with_lock do
      next if AccountUser.exists?(account_id: account.id, user_id: user.id)
      next if pending_only && !NotificationSetting.exists?(account_id: account.id, user_id: user.id)

      destroy_notification_setting(account, user)
      remove_user_from_teams(account, user)
      remove_user_from_inboxes(account, user)
      unassign_conversations(account, user)
    end
  end

  private

  def remove_user_from_inboxes(account, user)
    inboxes = account.inboxes.all
    inbox_members = user.inbox_members.where(inbox_id: inboxes.pluck(:id))
    inbox_members.destroy_all
  end

  def remove_user_from_teams(account, user)
    teams = account.teams.all
    team_members = user.team_members.where(team_id: teams.pluck(:id))
    team_members.destroy_all
  end

  def destroy_notification_setting(account, user)
    setting = user.notification_settings.find_by(account_id: account.id)
    setting&.destroy!
  end

  def unassign_conversations(account, user)
    # rubocop:disable Rails/SkipsModelValidations
    unassigned_count = user.assigned_conversations.where(account: account).in_batches.update_all(assignee_id: nil)
    # rubocop:enable Rails/SkipsModelValidations

    return unless unassigned_count.positive?

    ::Conversations::UnreadCounts::FilteredCountInvalidator.new(account).conversation_changed!
  end
end
