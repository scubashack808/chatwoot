require 'rails_helper'

# This stateful fake IMAP server needs separate memoized handles for mailboxes, UIDs, failures,
# the leased connection, and the durable database records it coordinates.
# rubocop:disable RSpec/MultipleMemoizedHelpers
RSpec.describe Imap::MailboxOperationExecutor do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:message) do
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :incoming, source_id: 'first@example.com')
  end
  let(:identity) do
    Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'])
  end
  let(:item) do
    {
      'message_id' => message.id,
      'identity_version' => identity.version,
      'source' => identity.primary,
      'provider_id' => identity.provider_id,
      'message_source_id' => message.source_id
    }
  end
  let(:operation) do
    create(
      :email_mailbox_operation,
      account: account,
      inbox: inbox,
      conversation: conversation,
      user: administrator,
      action: :archive,
      items: [item]
    )
  end
  let(:session) { instance_double(Imap::Session) }
  let(:client) { instance_double(Net::IMAP) }
  let(:connection_service) { instance_double(Imap::BaseFetchEmailService) }
  let(:selected) { { mailbox: nil } }
  let(:last_copyuid) { { value: nil } }
  let(:failed_uids) { [] }
  let(:next_uids) { Hash.new(20) }
  let(:uidvalidities) do
    { 'INBOX' => 42, 'INBOX.Archive' => 99, 'INBOX.Trash' => 100, 'INBOX.spam' => 101 }
  end
  let(:server) do
    {
      'INBOX' => { 7 => 'first@example.com' },
      'INBOX.Archive' => {},
      'INBOX.Trash' => {},
      'INBOX.spam' => {}
    }
  end
  let(:folders) do
    [
      Net::IMAP::MailboxList.new([:Hasnochildren], '.', 'INBOX'),
      Net::IMAP::MailboxList.new([:Archive, :Hasnochildren], '.', 'INBOX.Archive'),
      Net::IMAP::MailboxList.new([:Trash, :Hasnochildren], '.', 'INBOX.Trash'),
      Net::IMAP::MailboxList.new([:Junk, :Hasnochildren], '.', 'INBOX.spam')
    ]
  end
  let(:copy_uid_class) { Struct.new(:uidvalidity, :source_uids, :assigned_uids) }

  before do
    account.enable_features!(:email_mailbox_actions)
    channel.update!(mailbox_sync_config: { 'mode' => 'active' })
    message.write_imap_identity!(identity)

    allow(Imap::BaseFetchEmailService).to receive(:for).with(channel).and_return(connection_service)
    allow(connection_service).to receive(:with_connection).and_yield(client, session)
    allow(session).to receive(:command).and_yield(client)

    allow(client).to receive(:capabilities).and_return(%w[MOVE UIDPLUS])
    allow(client).to receive(:list).with('', '*').and_return(folders)
    allow(client).to receive(:select) { |mailbox| selected[:mailbox] = mailbox }
    allow(client).to receive(:responses).with('UIDVALIDITY') { [uidvalidities.fetch(selected[:mailbox])] }
    allow(client).to receive(:clear_responses).with('COPYUID') { last_copyuid[:value] = nil }
    allow(client).to receive(:responses).with('COPYUID') do
      last_copyuid[:value].nil? ? [] : [last_copyuid[:value]]
    end
    allow(client).to receive(:uid_search) do |query|
      case query.first
      when 'UID'
        server.fetch(selected[:mailbox]).key?(query.second) ? [query.second] : []
      when 'HEADER'
        server.fetch(selected[:mailbox]).filter_map { |uid, source_id| uid if source_id == query.third }
      else
        []
      end
    end
    allow(client).to receive(:uid_move) do |uid, target|
      raise Net::IMAP::NoResponseError, 'simulated provider rejection' if failed_uids.include?(uid)

      source_id = server.fetch(selected[:mailbox]).delete(uid)
      target_uid = next_uids[target] += 1
      server.fetch(target)[target_uid] = source_id
      last_copyuid[:value] = copy_uid_class.new(uidvalidities.fetch(target), [uid], [target_uid])
    end
  end

  it 'moves through the leased connection wrapper, records success, and bumps the identity once' do
    described_class.new(operation: operation).perform

    expect(connection_service).to have_received(:with_connection)
    expect(client).to have_received(:uid_move).with(7, 'INBOX.Archive').once
    expect(operation.reload).to have_attributes(status: 'succeeded', attempt_count: 1)
    expect(operation.recorded_results).to contain_exactly(
      include('message_id' => message.id, 'status' => 'succeeded',
              'target' => include('mailbox' => 'INBOX.Archive', 'uidvalidity' => 99, 'roles' => ['archive']))
    )

    updated_identity = message.reload.imap_identity
    expect(updated_identity).to have_attributes(mailbox: 'INBOX.Archive', uidvalidity: 99, version: 2)
    expect(updated_identity.locations.map { |location| location['mailbox'] }).to eq ['INBOX.Archive']
  end

  {
    trash: ['INBOX.Trash', 'trash'],
    spam: ['INBOX.spam', 'spam']
  }.each do |action, (target_mailbox, target_role)|
    it "moves tracked incoming messages to #{action} and keeps the conversation restorable" do
      operation.update!(action: action)

      described_class.new(operation: operation).perform

      expect(client).to have_received(:uid_move).with(7, target_mailbox).once
      expect(message.reload.imap_identity).to have_attributes(mailbox: target_mailbox, roles: [target_role], version: 2)
      expect(operation.reload.status).to eq 'succeeded'
      expect(Conversation).to exist(conversation.id)
    end
  end

  it 'restores a tracked Trash message to Inbox with the server-confirmed target identity' do
    trashed_identity = Imap::MessageIdentity.build(
      mailbox: 'INBOX.Trash', uidvalidity: 100, uid: 31, roles: ['trash']
    )
    message.write_imap_identity!(trashed_identity)
    server['INBOX'].delete(7)
    server['INBOX.Trash'][31] = 'first@example.com'
    operation.update!(
      action: :restore,
      items: [
        {
          'message_id' => message.id,
          'identity_version' => trashed_identity.version,
          'source' => trashed_identity.primary,
          'provider_id' => nil,
          'message_source_id' => message.source_id
        }
      ]
    )

    described_class.new(operation: operation).perform

    expect(client).to have_received(:uid_move).with(31, 'INBOX').once
    expect(message.reload.imap_identity).to have_attributes(mailbox: 'INBOX', roles: ['inbox'], version: 2)
    expect(operation.reload.status).to eq 'succeeded'
  end

  it 'restores Gmail by adding Inbox while retaining the existing All Mail location' do
    archived_identity = Imap::MessageIdentity.build(
      mailbox: '[Gmail]/All Mail', uidvalidity: 102, uid: 31, roles: ['archive']
    )
    message.write_imap_identity!(archived_identity)
    server['INBOX'].delete(7)
    server['[Gmail]/All Mail'] = { 31 => 'first@example.com' }
    uidvalidities['[Gmail]/All Mail'] = 102
    operation.update!(
      action: :restore,
      items: [
        {
          'message_id' => message.id,
          'identity_version' => archived_identity.version,
          'source' => archived_identity.primary,
          'provider_id' => nil,
          'message_source_id' => message.source_id
        }
      ]
    )
    allow(client).to receive(:capabilities).and_return(%w[X-GM-EXT-1 MOVE UIDPLUS])
    allow(client).to receive(:uid_store) { server['INBOX'][44] = 'first@example.com' }

    described_class.new(operation: operation).perform

    expect(client).to have_received(:uid_store).with(31, '+X-GM-LABELS', ['\\Inbox']).once
    expect(message.reload.imap_identity.locations.pluck('mailbox')).to contain_exactly('INBOX', '[Gmail]/All Mail')
  end

  it 'archives Gmail from the frozen Inbox location when All Mail is the identity primary' do
    gmail_identity = Imap::MessageIdentity
                     .build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'], provider_id: '9001')
                     .with_location(mailbox: '[Gmail]/All Mail', uidvalidity: 102, uid: 31, roles: ['archive'])
    message.write_imap_identity!(gmail_identity)
    server['[Gmail]/All Mail'] = { 31 => 'first@example.com' }
    uidvalidities['[Gmail]/All Mail'] = 102
    folders << Net::IMAP::MailboxList.new([:All, :Hasnochildren], '.', '[Gmail]/All Mail')
    operation.update!(
      items: [
        {
          'message_id' => message.id,
          'identity_version' => gmail_identity.version,
          'source' => gmail_identity.location_for('INBOX'),
          'provider_id' => '9001',
          'message_source_id' => message.source_id
        }
      ]
    )
    allow(client).to receive(:capabilities).and_return(%w[X-GM-EXT-1 MOVE UIDPLUS])
    allow(client).to receive(:uid_search).with(%w[X-GM-MSGID 9001]).and_return([31])
    allow(client).to receive(:uid_store) { server['INBOX'].delete(7) }

    described_class.new(operation: operation).perform

    expect(client).to have_received(:uid_store).with(7, '-X-GM-LABELS', ['\\Inbox']).once
    expect(client).not_to have_received(:uid_move)
    expect(message.reload.imap_identity).to have_attributes(mailbox: '[Gmail]/All Mail', version: 3)
    expect(message.imap_identity.locations.pluck('mailbox')).to eq ['[Gmail]/All Mail']
  end

  it 'records a frozen untracked item as conflict instead of hiding it from a partial result' do
    untracked = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      source_id: 'untracked@example.com'
    )
    operation.update!(
      items: [
        item,
        {
          'message_id' => untracked.id,
          'message_source_id' => untracked.source_id,
          'preflight_error' => 'identity_missing'
        }
      ]
    )

    described_class.new(operation: operation).perform

    expect(operation.reload.status).to eq 'partially_succeeded'
    expect(operation.recorded_results.pluck('status')).to contain_exactly('succeeded', 'conflict')
    expect(client).to have_received(:uid_move).once
  end

  it 'rechecks active mode immediately before mutation and leaves provider state untouched when it closes' do
    allow(client).to receive(:uid_search).with(['UID', 7]) do
      channel.update_column(:mailbox_sync_config, channel.mailbox_sync.to_h.merge('mode' => 'observe')) # rubocop:disable Rails/SkipsModelValidations
      [7]
    end

    described_class.new(operation: operation).perform

    expect(client).not_to have_received(:uid_move)
    expect(operation.reload).to have_attributes(status: 'failed', error_code: 'mailbox_sync_not_active')
    expect(message.reload.imap_identity).to have_attributes(mailbox: 'INBOX', version: 1)
  end

  it 'reauthorizes the actor in the worker before opening a provider connection' do
    administrator.account_users.find_by!(account: account).destroy!

    described_class.new(operation: operation).perform

    expect(connection_service).not_to have_received(:with_connection)
    expect(operation.reload).to have_attributes(status: 'failed', error_code: 'actor_not_authorized')
    expect(client).not_to have_received(:uid_move)
  end

  it 'records exact per-message partial failure and changes only the confirmed identity' do
    second_message = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      source_id: 'second@example.com'
    )
    second_identity = Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 8, roles: ['inbox'])
    second_message.write_imap_identity!(second_identity)
    server['INBOX'][8] = 'second@example.com'
    failed_uids << 8
    operation.update!(
      items: [
        item,
        {
          'message_id' => second_message.id,
          'identity_version' => second_identity.version,
          'source' => second_identity.primary,
          'provider_id' => nil,
          'message_source_id' => second_message.source_id
        }
      ]
    )

    described_class.new(operation: operation).perform

    expect(operation.reload.status).to eq 'partially_succeeded'
    expect(operation.recorded_results.pluck('status')).to contain_exactly('succeeded', 'failed')
    expect(message.reload.imap_identity.mailbox).to eq 'INBOX.Archive'
    expect(second_message.reload.imap_identity.mailbox).to eq 'INBOX'
  end

  it 'retries only unresolved items and replaces their prior failure result' do
    second_message = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      source_id: 'second@example.com'
    )
    second_identity = Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 8, roles: ['inbox'])
    second_message.write_imap_identity!(second_identity)
    server['INBOX'][8] = 'second@example.com'
    failed_uids << 8
    operation.update!(
      items: [
        item,
        {
          'message_id' => second_message.id,
          'identity_version' => second_identity.version,
          'source' => second_identity.primary,
          'provider_id' => nil,
          'message_source_id' => second_message.source_id
        }
      ]
    )

    described_class.new(operation: operation).perform
    failed_uids.clear
    operation.update!(status: :pending)
    described_class.new(operation: operation.reload).perform

    expect(client).to have_received(:uid_move).with(7, 'INBOX.Archive').once
    expect(client).to have_received(:uid_move).with(8, 'INBOX.Archive').twice
    expect(operation.reload).to have_attributes(status: 'succeeded', attempt_count: 2)
    expect(operation.recorded_results.pluck('status')).to contain_exactly('succeeded', 'succeeded')
  end

  it 'converges after the server move succeeds and the process dies before any database write' do
    simulated_process_death = Class.new(Exception) # rubocop:disable Lint/InheritException
    first_executor = described_class.new(operation: operation)
    allow(first_executor).to receive(:persist_success).and_raise(simulated_process_death)

    expect { first_executor.perform }.to raise_error(simulated_process_death)
    expect(server['INBOX.Archive'].values).to contain_exactly('first@example.com')
    expect(operation.reload.recorded_results).to be_empty
    expect(message.reload.imap_identity).to have_attributes(mailbox: 'INBOX', version: 1)

    described_class.new(operation: operation.reload).perform

    expect(client).to have_received(:uid_move).with(7, 'INBOX.Archive').once
    expect(operation.reload).to have_attributes(status: 'succeeded', attempt_count: 2)
    expect(message.reload.imap_identity).to have_attributes(mailbox: 'INBOX.Archive', version: 2)
  end

  it 'leaves the operation pending when another inbox worker owns the lease' do
    allow(connection_service).to receive(:with_connection).and_raise(Imap::Lease::LeaseNotAcquiredError)

    expect { described_class.new(operation: operation).perform }
      .to raise_error(Imap::Lease::LeaseNotAcquiredError)

    expect(operation.reload.status).to eq 'pending'
    expect(client).not_to have_received(:uid_move)
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers
