require 'rails_helper'
require Rails.root.join('db/migrate/20260504100000_add_aliases_to_channel_email')

# Row 09 behaviour B03: preserve the production alias migration identity and data.
#
# Production already recorded version 20260504100000 for exactly this migration, so Rails skips
# it there on version alone. The migration is still written to be idempotent, because a
# production-shaped database restored without its schema_migrations row would otherwise fail on
# a duplicate column.
RSpec.describe AddAliasesToChannelEmail do
  subject(:migration) { described_class.new }

  let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) }

  it 'keeps the production migration version' do
    expect(described_class.name.underscore).to eq('add_aliases_to_channel_email')
    expect(Dir[Rails.root.join('db/migrate/20260504100000_*.rb')].size).to eq(1)
  end

  describe '#up' do
    it 'adds the column and the GIN index on a clean database' do
      allow(connection).to receive(:column_exists?).with('channel_email', :aliases).and_return(false)
      allow(connection).to receive(:index_exists?).with('channel_email', :aliases, using: 'gin').and_return(false)

      expect(connection).to receive(:add_column).with('channel_email', :aliases, :string, array: true, default: [])
      expect(connection).to receive(:add_index).with('channel_email', :aliases, using: 'gin')

      migration.exec_migration(connection, :up)
    end

    it 'does nothing on a production-shaped database that already has the column and index' do
      allow(connection).to receive(:column_exists?).with('channel_email', :aliases).and_return(true)
      allow(connection).to receive(:index_exists?).with('channel_email', :aliases, using: 'gin').and_return(true)

      expect(connection).not_to receive(:add_column)
      expect(connection).not_to receive(:add_index)

      migration.exec_migration(connection, :up)
    end

    it 'adds only the missing index on a partially migrated database' do
      allow(connection).to receive(:column_exists?).with('channel_email', :aliases).and_return(true)
      allow(connection).to receive(:index_exists?).with('channel_email', :aliases, using: 'gin').and_return(false)

      expect(connection).not_to receive(:add_column)
      expect(connection).to receive(:add_index).with('channel_email', :aliases, using: 'gin')

      migration.exec_migration(connection, :up)
    end
  end

  describe '#down' do
    it 'never drops the column, because live production alias values are in it' do
      expect(connection).not_to receive(:remove_column)

      migration.exec_migration(connection, :down)
    end
  end
end
