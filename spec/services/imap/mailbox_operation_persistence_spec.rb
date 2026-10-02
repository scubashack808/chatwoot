require 'rails_helper'

# Real commits are essential here: fixture rollback would hide the identity/result persistence gap.
# rubocop:disable RSpec/MultipleMemoizedHelpers
RSpec.describe Imap::MailboxOperationExecutor do # rubocop:disable RSpec/SpecFilePathFormat
  self.use_transactional_tests = false

  let!(:account) { create(:account) }
  let!(:administrator) { create(:user, account: account, role: :administrator) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: conversation.contact,
                     message_type: :incoming, source_id: 'committed-boundary@example.com')
  end
  let(:identity) { Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox']) }
  let(:idempotency_key) { SecureRandom.uuid }
  let(:request) do
    Imap::MailboxOperationRequest.new(conversation: conversation, user: administrator, action: :archive,
                                      idempotency_key: idempotency_key)
  end
  let(:operation) { request.perform.operation }
  # Escape the executor's StandardError rescue, as an abrupt process interruption would.
  let(:interruption) { Class.new(Exception) } # rubocop:disable Lint/InheritException
  let(:client) { instance_double(Net::IMAP) }
  let(:session) { instance_double(Imap::Session) }
  let(:connection_service) { instance_double(Imap::BaseFetchEmailService) }
  let(:selected) { { mailbox: nil } }
  let(:copyuid) { { value: nil } }
  let(:network_transactions) { [] }
  let(:server) { { 'INBOX' => { 7 => message.source_id }, 'INBOX.Archive' => {} } }
  let(:uidvalidities) { { 'INBOX' => 42, 'INBOX.Archive' => 99 } }
  let(:folders) do
    [Net::IMAP::MailboxList.new([:Hasnochildren], '.', 'INBOX'),
     Net::IMAP::MailboxList.new([:Archive, :Hasnochildren], '.', 'INBOX.Archive')]
  end

  before do
    Current.reset
    account.enable_features!(:email_mailbox_actions)
    channel.update!(mailbox_sync_config: { 'mode' => 'active' })
    message.write_imap_identity!(identity)

    allow(Imap::BaseFetchEmailService).to receive(:for).with(channel).and_return(connection_service)
    allow(connection_service).to receive(:with_connection).and_yield(client, session)
    allow(session).to receive(:command) do |&command|
      network_transactions << ActiveRecord::Base.connection.transaction_open?
      command.call(client)
    end
    allow(client).to receive(:capabilities).and_return(%w[MOVE UIDPLUS])
    allow(client).to receive(:list).with('', '*').and_return(folders)
    allow(client).to receive(:select) { |mailbox| selected[:mailbox] = mailbox }
    allow(client).to receive(:responses).with('UIDVALIDITY') { [uidvalidities.fetch(selected[:mailbox])] }
    allow(client).to receive(:clear_responses).with('COPYUID') { copyuid[:value] = nil }
    allow(client).to receive(:responses).with('COPYUID') { copyuid[:value] ? [copyuid[:value]] : [] }
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
      network_transactions << ActiveRecord::Base.connection.transaction_open?
      source_id = server.fetch(selected[:mailbox]).delete(uid)
      server.fetch(target)[21] = source_id
      copyuid[:value] = Struct.new(:uidvalidity, :source_uids, :assigned_uids).new(uidvalidities.fetch(target), [uid], [21])
    end
  end

  after do
    # Account/Conversation/User use destroy_async. Execute only their owned deletion jobs, not delivery jobs.
    EmailMailboxOperation.where(account_id: account.id).delete_all
    perform_enqueued_jobs(only: ActiveRecord::DestroyAssociationAsyncJob) do
      account.conversations.destroy_all
      account.contacts.destroy_all
      account.inboxes.destroy_all
      account.reload.destroy!
      administrator.reload.destroy!
    end
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    Current.reset
  end

  # Keep the complete boundary/result assertions together and reuse them across the recovery cases.
  # rubocop:disable Metrics/AbcSize
  def expect_one_committed_move
    persisted = EmailMailboxOperation.find(operation.id)
    persisted_message = Message.find(message.id)
    expect(persisted.status).to eq('succeeded')
    expect(persisted.frozen_items.first['identity_version']).to eq(1)
    expect(persisted.recorded_results).to contain_exactly(
      'message_id' => message.id, 'status' => 'succeeded', 'source' => identity.primary,
      'target' => { 'mailbox' => 'INBOX.Archive', 'uidvalidity' => 99, 'uid' => 21, 'roles' => ['archive'], 'identity_version' => 2 }
    )
    expect(persisted_message.imap_identity.version).to eq(2)
    expect(persisted_message.imap_identity.locations).to eq(
      [{ 'mailbox' => 'INBOX.Archive', 'uidvalidity' => 99, 'uid' => 21, 'roles' => ['archive'] }]
    )
    expect(client).to have_received(:uid_move).with(7, 'INBOX.Archive').once
    expect(server).to eq('INBOX' => {}, 'INBOX.Archive' => { 21 => message.source_id })
    expect(network_transactions).not_to be_empty
    expect(network_transactions).to all(be(false))
  end

  # Reproduce and verify the same committed gap for fresh retry, request resume and interrupted replay.
  def interrupt_after_identity_commit
    allow(operation).to receive(:record_result!) do
      expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
      committed_message = Message.find(message.id)
      committed_operation = EmailMailboxOperation.find(operation.id)
      receipt = committed_message.external_source_ids.fetch('imap').fetch('mailbox_operation_receipt')
      expect(committed_message.imap_identity.version).to eq(2)
      expect(receipt).to include('operation_id' => operation.id, 'item' => committed_operation.frozen_items.first,
                                 'identity' => committed_message.imap_identity.to_h)
      expect(receipt.fetch('result')).to include('status' => 'succeeded', 'message_id' => message.id)
      expect(committed_operation).to have_attributes(status: 'running', results: [])
      expect(committed_operation.frozen_items.first['identity_version']).to eq(1)
      raise interruption
    end
    expect { described_class.new(operation: operation).perform }.to raise_error(interruption)
    expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
  end

  # rubocop:enable Metrics/AbcSize

  it 'commits an uninterrupted move and its result' do
    described_class.new(operation: operation).perform

    expect_one_committed_move
  end

  it 'recovers a provider move interrupted before any identity write' do
    executor = described_class.new(operation: operation)
    allow(executor).to receive(:persist_success).and_raise(interruption)
    expect { executor.perform }.to raise_error(interruption)

    expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
    expect(Message.find(message.id).imap_identity.version).to eq(1)
    expect(EmailMailboxOperation.find(operation.id).recorded_results).to be_empty
    described_class.new(operation: EmailMailboxOperation.find(operation.id)).perform

    expect_one_committed_move
  end

  it 'recovers a committed identity and receipt with a fresh executor after interruption before the result write' do
    interrupt_after_identity_commit

    described_class.new(operation: EmailMailboxOperation.find(operation.id)).perform

    expect_one_committed_move
  end

  %w[failed conflict].each do |previous_status|
    it "resumes the same request and replaces a previous #{previous_status} result" do
      interrupt_after_identity_commit
      previous = EmailMailboxOperation.find(operation.id)
      previous.record_result!('message_id' => message.id, 'status' => previous_status,
                              'source' => identity.primary, 'error_code' => 'identity_version_changed')
      previous.complete!
      frozen_items = previous.frozen_items
      resumed = Imap::MailboxOperationRequest.new(
        conversation: Conversation.find(conversation.id), user: User.find(administrator.id),
        action: :archive, idempotency_key: idempotency_key
      ).perform
      expect(resumed).to be_accepted
      expect(resumed.operation).to have_attributes(id: operation.id, status: 'pending', items: frozen_items)
      expect(EmailMailboxOperation.where(account_id: account.id).count).to eq(1)

      described_class.new(operation: EmailMailboxOperation.find(resumed.operation.id)).perform

      expect_one_committed_move
    end
  end

  it 'keeps the committed receipt recoverable when recording its replay is also interrupted' do
    interrupt_after_identity_commit
    retry_operation = EmailMailboxOperation.find(operation.id)
    receipt = Message.find(message.id).external_source_ids.fetch('imap').fetch('mailbox_operation_receipt')
    allow(retry_operation).to receive(:record_result!).and_raise(interruption)
    expect { described_class.new(operation: retry_operation).perform }.to raise_error(interruption)

    expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
    expect(EmailMailboxOperation.find(operation.id).recorded_results).to be_empty
    expect(Message.find(message.id).external_source_ids.dig('imap', 'mailbox_operation_receipt')).to eq(receipt)
    described_class.new(operation: EmailMailboxOperation.find(operation.id)).perform

    expect_one_committed_move
  end

  it 'does not attribute an unrelated move to the same target without provenance' do
    admitted = operation
    server.fetch('INBOX.Archive')[21] = server.fetch('INBOX').delete(7)
    message.write_imap_identity!(identity.moved_to(mailbox: 'INBOX.Archive', uidvalidity: 99, uid: 21,
                                                   roles: ['archive'], source_mailbox: 'INBOX'))

    described_class.new(operation: EmailMailboxOperation.find(admitted.id)).perform

    expect(EmailMailboxOperation.find(admitted.id)).to have_attributes(status: 'conflict', error_code: 'identity_version_changed')
    expect(Message.find(message.id).imap_identity.version).to eq(2)
    expect(Message.find(message.id).external_source_ids.fetch('imap')).not_to have_key('mailbox_operation_receipt')
    expect(client).not_to have_received(:uid_move)
    expect(server).to eq('INBOX' => {}, 'INBOX.Archive' => { 21 => message.source_id })
    expect(network_transactions).not_to be_empty
    expect(network_transactions).to all(be(false))
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers
