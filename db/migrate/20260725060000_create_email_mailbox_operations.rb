class CreateEmailMailboxOperations < ActiveRecord::Migration[7.1]
  # One narrow durable table, deliberately not a general operation framework and not a normalised
  # child-result table. The row exists because Sidekiq alone cannot give two users a durable
  # pending, partial or failed result, and because it stops a retry from re-moving messages.
  def change
    create_email_mailbox_operations
    add_email_mailbox_operation_indexes
  end

  private

  def create_email_mailbox_operations
    create_table :email_mailbox_operations do |t|
      t.references :account, null: false, index: true
      t.references :inbox, null: false, index: true
      t.references :conversation, null: false, index: true
      t.bigint :user_id
      t.integer :action, null: false
      t.string :idempotency_key, null: false
      t.integer :status, default: 0, null: false
      t.integer :attempt_count, default: 0, null: false
      t.string :error_code
      # Frozen at creation: each eligible message id with the identity version and source location
      # it was planned against. A retry resolves these, never a freshly derived set.
      t.jsonb :items, default: [], null: false
      # Per message: source identity, server-confirmed target identity, and outcome.
      t.jsonb :results, default: [], null: false

      t.timestamps
    end
  end

  def add_email_mailbox_operation_indexes
    add_index :email_mailbox_operations, [:account_id, :idempotency_key],
              unique: true, name: 'idx_email_mailbox_operations_on_account_and_key'

    # At most one nonterminal operation per conversation: pending(0) and running(1). A second
    # action against the same conversation gets a visible conflict instead of racing.
    add_index :email_mailbox_operations, [:conversation_id],
              unique: true, where: 'status IN (0, 1)',
              name: 'idx_email_mailbox_operations_one_active_per_conversation'

    add_index :email_mailbox_operations, [:user_id], name: 'idx_email_mailbox_operations_on_user'
  end
end
