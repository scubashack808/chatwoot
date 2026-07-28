class AddAliasesToChannelEmail < ActiveRecord::Migration[7.1]
  # This version number is the production one, preserved exactly. The deployed Extended Horizons
  # fork recorded 20260504100000 for this migration and four live alias values sit in the column
  # today, so a production database skips this migration on its version alone and its data is
  # untouched. Upstream v4.16 has no migration at this version, so there is no collision to
  # repair here (unlike the team-icon one at 20260616120000).
  #
  # It is written idempotently anyway: a production-shaped database restored without its
  # schema_migrations row would otherwise fail on a duplicate column.
  def up
    add_column :channel_email, :aliases, :string, array: true, default: [] unless column_exists?(:channel_email, :aliases)
    add_index :channel_email, :aliases, using: 'gin' unless index_exists?(:channel_email, :aliases, using: 'gin')
  end

  # Never drop the column. It holds live production alias values and rolling back this
  # compatibility patch must not destroy them.
  def down; end
end
