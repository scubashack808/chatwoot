require 'rails_helper'
require Rails.root.join('db/migrate/20260723045706_repair_team_icon_columns_after_legacy_collision')

RSpec.describe RepairTeamIconColumnsAfterLegacyCollision do
  subject(:migration) { described_class.new }

  let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) }

  describe '#up' do
    it 'adds both team icon columns on a database affected by the migration collision' do
      allow(connection).to receive(:column_exists?).with('teams', :icon).and_return(false)
      allow(connection).to receive(:column_exists?).with('teams', :icon_color).and_return(false)

      expect(connection).to receive(:add_column).with('teams', :icon, :string, default: '')
      expect(connection).to receive(:add_column).with('teams', :icon_color, :string, default: '')

      migration.exec_migration(connection, :up)
    end

    it 'does nothing when the upstream migration already added both columns' do
      allow(connection).to receive(:column_exists?).with('teams', :icon).and_return(true)
      allow(connection).to receive(:column_exists?).with('teams', :icon_color).and_return(true)

      expect(connection).not_to receive(:add_column)

      migration.exec_migration(connection, :up)
    end

    it 'repairs only the missing column on a partially repaired database' do
      allow(connection).to receive(:column_exists?).with('teams', :icon).and_return(true)
      allow(connection).to receive(:column_exists?).with('teams', :icon_color).and_return(false)

      expect(connection).not_to receive(:add_column).with('teams', :icon, :string, default: '')
      expect(connection).to receive(:add_column).with('teams', :icon_color, :string, default: '')

      migration.exec_migration(connection, :up)
    end
  end

  describe '#down' do
    it 'does not remove columns that can be owned by the upstream migration' do
      expect(connection).not_to receive(:remove_column)

      migration.exec_migration(connection, :down)
    end
  end
end
