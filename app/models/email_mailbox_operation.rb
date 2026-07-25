# == Schema Information
#
# Table name: email_mailbox_operations
#
#  id              :bigint           not null, primary key
#  action          :integer          not null
#  attempt_count   :integer          default(0), not null
#  error_code      :string
#  idempotency_key :string           not null
#  items           :jsonb            not null
#  results         :jsonb            not null
#  status          :integer          default("pending"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  conversation_id :bigint           not null
#  inbox_id        :bigint           not null
#  user_id         :bigint
#

# One durable record of one mailbox action against one conversation.
#
# It exists so that two people looking at the same conversation see the same pending, partial,
# failed or conflict result, and so that a retry resumes the same operation instead of moving
# messages a second time. It is intentionally not a generic state machine.
#
# The row never holds a raw message body, a credential, a token, or an unsanitised server
# exception; error_code is a normalised short string.
class EmailMailboxOperation < ApplicationRecord
  ACTIONS = %w[archive trash spam restore].freeze
  NONTERMINAL_STATUSES = %w[pending running].freeze

  belongs_to :account
  belongs_to :inbox
  belongs_to :conversation
  belongs_to :user, optional: true

  enum action: { archive: 0, trash: 1, spam: 2, restore: 3 }, _prefix: :action
  enum status: { pending: 0, running: 1, succeeded: 2, partially_succeeded: 3, failed: 4, conflict: 5 }

  validates :idempotency_key, presence: true, uniqueness: { scope: :account_id }

  scope :nonterminal, -> { where(status: NONTERMINAL_STATUSES) }

  def terminal?
    NONTERMINAL_STATUSES.exclude?(status)
  end

  def frozen_items
    Array(items).map { |item| item.to_h.transform_keys(&:to_s) }
  end

  def recorded_results
    Array(results).map { |result| result.to_h.transform_keys(&:to_s) }
  end

  def start_attempt!
    with_lock do
      update!(status: :running, attempt_count: attempt_count + 1, error_code: nil)
    end
  end

  def record_result!(result)
    normalized = result.to_h.deep_stringify_keys

    with_lock do
      retained = recorded_results.reject { |existing| existing['message_id'] == normalized['message_id'] }
      update!(results: retained + [normalized])
    end
  end

  def record_error_code!(code)
    with_lock { update!(error_code: code) }
  end

  def complete!
    with_lock do
      derived_status = derive_status
      update!(status: derived_status, error_code: derived_status == :succeeded ? nil : error_code)
    end
  end

  def mark_failed!(code)
    with_lock { update!(status: :failed, error_code: code) }
  end

  def mark_pending!(code = nil)
    with_lock { update!(status: :pending, error_code: code) }
  end

  # Items with no terminal result yet. A retry resolves only these, so a message already moved is
  # never moved again.
  def unresolved_items
    resolved = recorded_results.select { |result| result['status'] == 'succeeded' }.pluck('message_id')

    frozen_items.reject { |item| resolved.include?(item['message_id']) }
  end

  # The safe summary handed to clients and to the realtime event. No bodies, no credentials, no
  # raw server text.
  def summary
    {
      id: id,
      action: action,
      status: status,
      attempt_count: attempt_count,
      error_code: error_code,
      total: frozen_items.length,
      succeeded: count_results('succeeded'),
      conflicted: count_results('conflict'),
      failed: count_results('failed')
    }
  end

  def count_results(status)
    recorded_results.count { |result| result['status'] == status }
  end

  # Derives the terminal status from the recorded per-message results.
  def derive_status
    return :conflict if frozen_items.any? && count_results('conflict') == frozen_items.length
    return :failed if count_results('succeeded').zero? && frozen_items.any?
    return :succeeded if count_results('succeeded') == frozen_items.length

    :partially_succeeded
  end
end
