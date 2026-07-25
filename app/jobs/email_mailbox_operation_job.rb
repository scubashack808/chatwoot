class EmailMailboxOperationJob < ApplicationJob
  queue_as :default

  def perform(operation_id)
    operation = EmailMailboxOperation.find_by(id: operation_id)
    return if operation.nil? || operation.terminal?

    Imap::MailboxOperationExecutor.new(operation: operation).perform
  rescue Imap::Lease::LeaseNotAcquiredError, Imap::Lease::LeaseLostError
    operation = EmailMailboxOperation.find_by(id: operation_id)
    return if operation.nil? || operation.terminal?

    self.class.set(wait: Imap::Lease.retry_delay(operation.attempt_count)).perform_later(operation.id)
  end
end
