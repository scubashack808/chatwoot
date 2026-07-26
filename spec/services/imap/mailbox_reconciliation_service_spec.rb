require 'rails_helper'

RSpec.describe Imap::MailboxReconciliationService do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:imap) { instance_double(Net::IMAP, disconnected?: false, disconnect: true, logout: true, capabilities: []) }
  let(:lease_key) { format(Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: inbox.id) }
  let(:tracker) { Imap::DeletedMessageTracker.new(inbox: inbox) }

  # Per-mailbox server contents. Each mailbox carries its own UIDVALIDITY generation so a bump in
  # one mailbox can be simulated without touching the others.
  let(:server) do
    {
      'INBOX' => { uidvalidity: 777, messages: [] },
      'INBOX.Archive' => { uidvalidity: 778, messages: [] },
      'INBOX.Trash' => { uidvalidity: 779, messages: [] },
      'INBOX.Junk' => { uidvalidity: 780, messages: [] },
      'INBOX.Projects' => { uidvalidity: 781, messages: [] }
    }
  end

  let(:folders) do
    [
      Net::IMAP::MailboxList.new([:Haschildren], '.', 'INBOX'),
      Net::IMAP::MailboxList.new([:Archive, :Hasnochildren], '.', 'INBOX.Archive'),
      Net::IMAP::MailboxList.new([:Trash, :Hasnochildren], '.', 'INBOX.Trash'),
      Net::IMAP::MailboxList.new([:Junk, :Hasnochildren], '.', 'INBOX.Junk'),
      Net::IMAP::MailboxList.new([:Hasnochildren], '.', 'INBOX.Projects'),
      Net::IMAP::MailboxList.new([:Noselect, :Haschildren], '.', 'INBOX.Container')
    ]
  end

  # Truncated batches are how a real partial read looks: the search reported UIDs the fetch never
  # returned. Setting this makes the given mailbox drop that many trailing fetch responses.
  let(:dropped_fetch_responses) { Hash.new(0) }

  def header_data(uid, message_id)
    Net::IMAP::FetchData.new(uid, 'UID' => uid,
                                  'BODY[HEADER.FIELDS (MESSAGE-ID)]' => "Message-ID: <#{message_id}>\r\n\r\n")
  end

  def place(mailbox, uid, message_id)
    server.fetch(mailbox)[:messages] << [uid, message_id]
  end

  def create_message(source_id)
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :incoming, source_id: source_id)
  end

  def tracked_message(source_id, mailbox: 'INBOX', uidvalidity: 777, uid: 11, roles: ['inbox'])
    message = create_message(source_id)
    message.write_imap_identity!(
      Imap::MessageIdentity.build(mailbox: mailbox, uidvalidity: uidvalidity, uid: uid, roles: roles)
    )
    message.reload
  end

  def reconcile
    described_class.new(channel: channel).perform
  end

  def state_for(target = conversation)
    Imap::ConversationMailboxState.new(conversation: target.reload).to_h
  end

  before do
    account.enable_features!(:email_mailbox_actions)
    channel.update!(mailbox_sync_config: { 'mode' => 'observe' })

    allow(Net::IMAP).to receive(:new).and_return(imap)
    allow(imap).to receive(:authenticate)
    allow(imap).to receive(:login)
    allow(imap).to receive(:select).with('INBOX')
    allow(imap).to receive(:list).with('', '*').and_return(folders)

    current = 'INBOX'
    allow(imap).to receive(:examine) { |mailbox| current = mailbox }
    allow(imap).to receive(:responses).with('UIDVALIDITY') { [server.fetch(current)[:uidvalidity]] }
    allow(imap).to receive(:uid_search).with(['ALL']) { server.fetch(current)[:messages].map(&:first) }
    allow(imap).to receive(:uid_fetch) do |batch, _attributes|
      selected = server.fetch(current)[:messages].select { |entry| Array(batch).include?(entry.first) }
      dropped = dropped_fetch_responses[current]
      selected = selected.first([selected.length - dropped, 0].max) if dropped.positive?
      selected.map { |uid, message_id| header_data(uid, message_id) }
    end
  end

  after { Redis::Alfred.delete(lease_key) }

  describe 'reading the server' do
    it 'opens every scanned mailbox read only so reconciliation cannot mutate the provider' do
      place('INBOX', 11, 'a@example.com')
      tracked_message('a@example.com')

      reconcile

      expect(imap).to have_received(:examine).with('INBOX')
      expect(imap).to have_received(:examine).with('INBOX.Archive')
      expect(imap).not_to have_received(:select).with('INBOX.Archive')
      expect(imap).not_to have_received(:select).with('INBOX.Trash')
    end

    it 'never fetches a message body' do
      place('INBOX', 11, 'a@example.com')
      tracked_message('a@example.com')

      reconcile

      expect(imap).to have_received(:uid_fetch).with(anything, array_including('BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]')).at_least(:once)
      expect(imap).not_to have_received(:uid_fetch).with(anything, array_including('BODY.PEEK[]'))
    end

    it 'skips folders the server marks as not selectable' do
      place('INBOX', 11, 'a@example.com')
      tracked_message('a@example.com')

      reconcile

      expect(imap).to have_received(:examine).with('INBOX.Junk')
      expect(imap).not_to have_received(:examine).with('INBOX.Container')
    end

    it 'scans folders that carry no mailbox role, so a move outside the four roles is still found' do
      place('INBOX.Projects', 4, 'a@example.com')
      tracked_message('a@example.com')

      reconcile

      expect(imap).to have_received(:examine).with('INBOX.Projects')
    end
  end

  # Exit row 1: a move performed outside Chatwoot is reflected in derived state.
  describe 'external move' do
    it 'follows a message an external client moved into the archive folder' do
      message = tracked_message('a@example.com', mailbox: 'INBOX', uid: 11)
      place('INBOX.Archive', 5, 'a@example.com')

      report = reconcile

      identity = message.reload.imap_identity
      expect(identity.mailbox).to eq 'INBOX.Archive'
      expect(identity.uid).to eq 5
      expect(identity.uidvalidity).to eq 778
      expect(identity.roles).to eq ['archive']
      expect(identity.sync_state).to eq 'verified'
      expect(report[:moved]).to eq 1
    end

    it 'reports the moved conversation in the existing derived state vocabulary' do
      tracked_message('a@example.com', mailbox: 'INBOX', uid: 11)
      place('INBOX.Trash', 3, 'a@example.com')

      reconcile

      expect(state_for).to include(state: 'trash', roles: ['trash'], missing_count: 0, tracked_count: 1)
    end

    it 'bumps the identity version so an operation frozen against the old location conflicts' do
      message = tracked_message('a@example.com', mailbox: 'INBOX', uid: 11)
      before_version = message.imap_identity.version
      place('INBOX.Archive', 5, 'a@example.com')

      reconcile

      expect(message.reload.imap_identity.version).to eq(before_version + 1)
    end

    it 'writes nothing when the server still agrees with the stored identity' do
      message = tracked_message('a@example.com', mailbox: 'INBOX', uid: 11)
      place('INBOX', 11, 'a@example.com')

      report = reconcile

      expect(message.reload.imap_identity.version).to eq 1
      expect(report[:unchanged]).to eq 1
      expect(report[:moved]).to eq 0
    end

    it 'keeps a message moved into a folder with no mailbox role out of the missing vocabulary' do
      message = tracked_message('a@example.com', mailbox: 'INBOX', uid: 11)
      place('INBOX.Projects', 4, 'a@example.com')

      reconcile
      reconcile

      identity = message.reload.imap_identity
      expect(identity.mailbox).to eq 'INBOX.Projects'
      expect(identity.sync_state).to eq 'verified'
      expect(state_for[:missing_count]).to eq 0
      expect(tracker.deleted?('a@example.com')).to be false
    end
  end

  # Exit row 2: a UIDVALIDITY change voids every cached UID and must not look like mass deletion.
  describe 'uidvalidity change' do
    it 'reresolves the uid by message id when the mailbox uidvalidity changed' do
      message = tracked_message('a@example.com', mailbox: 'INBOX', uidvalidity: 777, uid: 11)
      server['INBOX'][:uidvalidity] = 9001
      place('INBOX', 41, 'a@example.com')

      report = reconcile

      identity = message.reload.imap_identity
      expect(identity.uidvalidity).to eq 9001
      expect(identity.uid).to eq 41
      expect(identity.mailbox).to eq 'INBOX'
      expect(identity.sync_state).to eq 'verified'
      expect(report[:uidvalidity_resolved]).to eq 1
    end

    it 'never treats a uidvalidity bump as deletion, even across two cycles' do
      messages = %w[a@example.com b@example.com c@example.com].each_with_index.map do |source_id, position|
        tracked_message(source_id, mailbox: 'INBOX', uidvalidity: 777, uid: 11 + position)
      end
      server['INBOX'][:uidvalidity] = 9001
      messages.each_with_index { |message, position| place('INBOX', 900 + position, message.source_id) }

      reconcile
      report = reconcile

      expect(report[:marked_missing]).to eq 0
      expect(report[:absent_once]).to eq 0
      expect(messages.map { |message| message.reload.imap_identity.sync_state }.uniq).to eq ['verified']
      expect(state_for[:missing_count]).to eq 0
    end
  end

  # Exit row 3: the same Message-ID in two folders must resolve coherently and must not flap.
  describe 'duplicate message id' do
    it 'records every copy the server holds' do
      message = tracked_message('dupe@example.com', mailbox: 'INBOX', uid: 11)
      place('INBOX', 11, 'dupe@example.com')
      place('INBOX.Archive', 5, 'dupe@example.com')

      reconcile

      identity = message.reload.imap_identity
      expect(identity.locations.map { |location| location['mailbox'] }).to eq %w[INBOX INBOX.Archive]
      expect(identity.locations.map { |location| location['uid'] }).to eq [11, 5]
    end

    it 'settles after one cycle instead of flapping between the two folders' do
      message = tracked_message('dupe@example.com', mailbox: 'INBOX', uid: 11)
      place('INBOX', 11, 'dupe@example.com')
      place('INBOX.Trash', 3, 'dupe@example.com')

      reconcile
      first = message.reload.imap_identity.to_h
      reconcile
      second = message.reload.imap_identity.to_h
      reconcile
      third = message.reload.imap_identity.to_h

      # Both copies were actually taken up, so a pass that simply never wrote cannot satisfy this.
      expect(first['locations'].map { |location| location['mailbox'] }).to eq %w[INBOX INBOX.Trash]
      expect(second).to eq first
      expect(third).to eq first
    end

    it 'orders locations by role rather than by the order the server was scanned in' do
      # LIST reports Trash before Archive, so scan order and role order genuinely disagree here.
      allow(imap).to receive(:list).with('', '*')
                                   .and_return([folders[0], folders[2], folders[1], folders[3], folders[4], folders[5]])
      message = tracked_message('dupe@example.com', mailbox: 'INBOX.Trash', uidvalidity: 779, uid: 3)
      place('INBOX.Trash', 3, 'dupe@example.com')
      place('INBOX.Archive', 5, 'dupe@example.com')

      reconcile

      expect(message.reload.imap_identity.locations.map { |location| location['mailbox'] }).to eq %w[INBOX.Archive INBOX.Trash]
    end

    it 'derives one coherent state for a duplicated message' do
      tracked_message('dupe@example.com', mailbox: 'INBOX', uid: 11)
      place('INBOX', 11, 'dupe@example.com')
      place('INBOX.Archive', 5, 'dupe@example.com')

      reconcile

      expect(state_for).to include(state: 'mixed', roles: %w[inbox archive], missing_count: 0, tracked_count: 1)
    end
  end

  # Exit row 4: one cycle of absence is never enough, because a partial read looks the same.
  describe 'two cycle absence' do
    it 'takes no action on a single cycle of absence' do
      message = tracked_message('gone@example.com')

      report = reconcile

      expect(message.reload.imap_identity.sync_state).to eq 'stale'
      expect(state_for).to include(state: 'inbox', missing_count: 0)
      expect(tracker.deleted?('gone@example.com')).to be false
      expect(report[:absent_once]).to eq 1
      expect(report[:marked_missing]).to eq 0
    end

    it 'marks the identity missing on the second consecutive confirmed absence' do
      message = tracked_message('gone@example.com')

      reconcile
      report = reconcile

      expect(message.reload.imap_identity.sync_state).to eq 'missing'
      expect(report[:marked_missing]).to eq 1
    end

    it 'restarts the streak when the message reappears between cycles' do
      message = tracked_message('flaky@example.com')

      reconcile
      expect(message.reload.imap_identity.sync_state).to eq 'stale'

      place('INBOX', 11, 'flaky@example.com')
      reconcile
      expect(message.reload.imap_identity.sync_state).to eq 'verified'

      server['INBOX'][:messages] = []
      reconcile
      expect(message.reload.imap_identity.sync_state).to eq 'stale'
    end

    it 'refuses to conclude absence when a mailbox window could not be fully read' do
      message = tracked_message('gone@example.com')
      place('INBOX', 60, 'other@example.com')
      dropped_fetch_responses['INBOX'] = 1

      report = reconcile
      reconcile

      expect(message.reload.imap_identity.sync_state).to eq 'verified'
      expect(report[:inconclusive]).to eq 1
      expect(report[:absent_once]).to eq 0
    end

    it 'refuses to conclude absence when a mailbox is larger than the scan bound' do
      message = tracked_message('gone@example.com')
      stub_const("#{described_class}::MAX_MESSAGES_PER_MAILBOX", 2)
      3.times { |position| place('INBOX.Archive', position + 1, "bulk-#{position}@example.com") }

      report = reconcile
      reconcile

      expect(message.reload.imap_identity.sync_state).to eq 'verified'
      expect(report[:inconclusive]).to eq 1
    end

    it 'still follows moves it can see while a different mailbox window is untrustworthy' do
      moved = tracked_message('moved@example.com', mailbox: 'INBOX', uid: 11)
      place('INBOX.Archive', 5, 'moved@example.com')
      place('INBOX', 60, 'noise@example.com')
      dropped_fetch_responses['INBOX'] = 1

      reconcile

      expect(moved.reload.imap_identity.mailbox).to eq 'INBOX.Archive'
    end
  end

  # Exit row 5: external deletion lands in the derived state vocabulary that already exists.
  describe 'external deletion' do
    it 'reports the message through the existing missing vocabulary' do
      tracked_message('gone@example.com')

      reconcile
      reconcile

      expect(state_for).to include(state: 'mixed', missing_count: 1, tracked_count: 0, roles: [])
    end

    it 'drops the conversation out of every server side mailbox role list' do
      tracked_message('gone@example.com')

      reconcile
      reconcile

      %w[inbox archive trash spam].each do |role|
        filtered = Imap::MailboxRoleFilter.new(conversations: Conversation.where(id: conversation.id), role: role, account: account).perform
        expect(filtered).to be_empty, "expected the deleted conversation to be absent from the #{role} list"
      end
    end

    it 'refuses a new mailbox operation against a message the provider no longer holds' do
      channel.update!(mailbox_sync_config: { 'mode' => 'active' })
      tracked_message('gone@example.com')

      reconcile
      reconcile

      result = Imap::MailboxOperationRequest.new(
        conversation: conversation.reload, user: create(:user, account: account, role: :administrator),
        action: 'archive', idempotency_key: SecureRandom.uuid
      ).perform

      expect(result.operation.items.pluck('preflight_error')).to eq ['provider_missing']
    end
  end

  # Exit row 6: reconciliation must never turn into a mail resurrection machine.
  describe 'no recreate' do
    it 'records the provider tombstone when it concludes the message is gone' do
      tracked_message('gone@example.com')

      reconcile
      report = reconcile

      expect(tracker.deleted?('gone@example.com')).to be true
      expect(report[:tombstoned]).to eq 1
    end

    it 'refreshes the tombstone on later cycles so it cannot lapse while the message stays gone' do
      tracked_message('gone@example.com')

      reconcile
      reconcile
      Redis::Alfred.delete(format(Redis::RedisKeys::IMAP_DELETED_MESSAGE,
                                  inbox_id: inbox.id, message_id_digest: Digest::SHA256.hexdigest('gone@example.com')))
      expect(tracker.deleted?('gone@example.com')).to be false

      report = reconcile

      expect(tracker.deleted?('gone@example.com')).to be true
      expect(report[:tombstoned]).to eq 1
    end

    it 'never deletes the chatwoot message or its conversation' do
      message = tracked_message('gone@example.com')

      reconcile
      reconcile

      expect(Message.exists?(message.id)).to be true
      expect(Conversation.exists?(conversation.id)).to be true
    end

    it 'refuses re-ingestion on a later fetch cycle even after the chatwoot row is gone' do
      message = tracked_message('gone@example.com')

      reconcile
      reconcile
      message.destroy!

      expect(
        Imap::BaseFetchEmailService.for(channel).send(:email_already_present?, channel, 'gone@example.com')
      ).to be true
    end
  end

  # Exit row 7: with the feature off nothing runs at all.
  describe 'feature gate' do
    it 'runs no reconciliation work when the account feature is disabled' do
      account.disable_features!(:email_mailbox_actions)
      message = tracked_message('a@example.com')

      report = reconcile

      expect(Net::IMAP).not_to have_received(:new)
      expect(message.reload.imap_identity.sync_state).to eq 'verified'
      expect(report[:status]).to eq 'skipped'
      expect(report[:reason]).to eq 'feature_disabled'
    end

    it 'runs no reconciliation work when the inbox mailbox sync mode is off' do
      channel.update!(mailbox_sync_config: { 'mode' => 'off' })
      tracked_message('a@example.com')

      report = reconcile

      expect(Net::IMAP).not_to have_received(:new)
      expect(report[:reason]).to eq 'mailbox_sync_off'
    end

    it 'runs no reconciliation work when imap is disabled on the channel' do
      channel.update!(imap_enabled: false)
      tracked_message('a@example.com')

      report = reconcile

      expect(Net::IMAP).not_to have_received(:new)
      expect(report[:reason]).to eq 'imap_disabled'
    end

    it 'runs in observe mode, which never mutates the provider' do
      tracked_message('a@example.com', mailbox: 'INBOX', uid: 11)
      place('INBOX.Archive', 5, 'a@example.com')

      report = reconcile

      expect(report[:status]).to eq 'completed'
      expect(report[:moved]).to eq 1
    end
  end

  # Exit row 8: reconciliation must not become per-conversation work.
  describe 'query count' do
    def sql_count(&)
      queries = []
      subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:cached] || payload[:name] == 'SCHEMA'

        queries << payload[:sql]
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
      queries.length
    end

    it 'keeps a no-op cycle flat as the tracked message count grows' do
      measurements = [2, 12].map do |message_count|
        server['INBOX'][:messages] = []
        Message.where(inbox_id: inbox.id).destroy_all
        message_count.times do |position|
          source_id = "bulk-#{message_count}-#{position}@example.com"
          tracked_message(source_id, mailbox: 'INBOX', uid: 100 + position)
          place('INBOX', 100 + position, source_id)
        end

        # Reloaded so both measurements start from the same cold association cache.
        channel.reload
        report = nil
        count = sql_count { report = reconcile }
        [count, report]
      end

      # Both cycles really did examine every tracked message; the flat count is not a flat no-op.
      expect(measurements.map { |_count, report| report[:unchanged] }).to eq [2, 12]
      expect(measurements.first.first).to eq measurements.last.first
    end

    it 'leaves the bulk read surface at its constant query count when identities carry reconciled state' do
      counts = [1, 5].map do |conversation_count|
        conversations = create_list(:conversation, conversation_count, account: account, inbox: inbox)
        conversations.each_with_index do |target, position|
          message = create(:message, account: account, inbox: inbox, conversation: target, message_type: :incoming)
          identity = Imap::MessageIdentity.build(mailbox: 'INBOX.Archive', uidvalidity: 778, uid: position + 1, roles: ['archive'])
          message.write_imap_identity!(position.even? ? identity.with_sync_state('missing') : identity)
          create(:email_mailbox_operation, account: account, inbox: inbox, conversation: target)
        end

        sql_count { Imap::ConversationMailboxData.new(conversations: conversations).to_h }
      end

      expect(counts).to eq [2, 2]
    end
  end
end
