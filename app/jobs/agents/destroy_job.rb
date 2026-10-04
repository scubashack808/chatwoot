class Agents::DestroyJob < ApplicationJob
  queue_as :low

  def perform(account, user)
    Agents::AccountUserCleanupService.new.perform(account, user)
  end
end
