class AddMailboxSyncConfigToChannelEmail < ActiveRecord::Migration[7.1]
  # Every inbox starts off. The stored default carries that explicitly rather than relying on an
  # empty object, so an existing row reads as off without the application inferring it.
  #
  # PostgreSQL applies a non-volatile column default to existing rows, so the backfill is the
  # default itself. Kept idempotent for the same reason as the collision repair: this line is
  # replayed against databases in more than one state.
  DEFAULT_CONFIG = { 'mode' => 'off', 'sent_mode' => 'provider_managed', 'folder_overrides' => {} }.freeze

  def up
    return if column_exists?(:channel_email, :mailbox_sync_config)

    add_column :channel_email, :mailbox_sync_config, :jsonb, default: DEFAULT_CONFIG, null: false
  end

  def down
    remove_column :channel_email, :mailbox_sync_config if column_exists?(:channel_email, :mailbox_sync_config)
  end
end
