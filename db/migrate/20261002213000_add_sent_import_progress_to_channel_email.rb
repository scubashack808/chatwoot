class AddSentImportProgressToChannelEmail < ActiveRecord::Migration[7.1]
  def change
    add_column :channel_email, :sent_import_progress, :jsonb, default: {}, null: false
  end
end
