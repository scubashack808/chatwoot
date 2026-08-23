class RepairTeamIconColumnsAfterLegacyCollision < ActiveRecord::Migration[7.1]
  # The deployed Extended Horizons fork already recorded migration version
  # 20260616120000 for a different migration. Upstream v4.16 uses that version
  # for AddIconToTeams, so Rails skips the upstream migration on that database.
  #
  # Keep this repair idempotent so it is also safe on ordinary v4.16 databases
  # where the upstream migration ran normally.
  def up
    add_column :teams, :icon, :string, default: '' unless column_exists?(:teams, :icon)
    add_column :teams, :icon_color, :string, default: '' unless column_exists?(:teams, :icon_color)
  end

  # These columns may be owned by the upstream migration rather than this
  # repair. Never remove them while rolling back only the compatibility patch.
  def down; end
end
