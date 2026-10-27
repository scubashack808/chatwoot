raise 'Use the isolated test runner' unless ENV['RAILS_ENV'] == 'test' && !ENV.fetch('WOOT59_IMAP_HOST', '').empty?

require 'rails_helper'
require 'net/imap'

RSpec.describe Imap::MessageIdMatcher do
  let(:session) { Imap::Session.new(connect_timeout: 5, command_timeout: 10) }
  let(:client) { session.client }

  around do |example|
    session.connect { Net::IMAP.new(ENV.fetch('WOOT59_IMAP_HOST'), port: 31_143, ssl: false) }
    session.command { |imap| imap.login("woot59-#{SecureRandom.hex(10)}", 'woot59-synthetic-only') }
    %w[Archive Other Sent].each { |folder| session.command { |imap| imap.create(folder) } }
    example.run
  ensure
    session.close
  end

  # Shared only by protocol fixtures: every message is encoded, appended and fetched on the server.
  def append_message(folder, id)
    mail = Mail.new(from: 'sender@example.test', to: 'recipient@example.test', message_id: id,
                    subject: 'Synthetic identity fixture', body: 'No SMTP delivery')
    session.command { |imap| imap.append(folder, mail.encoded, [], Time.current) }
  end

  def headers(folder)
    session.command { |imap| imap.examine(folder) }
    uids = session.command { |imap| imap.uid_search(['ALL']) }
    return [] if uids.empty?

    session.command { |imap| imap.uid_fetch(uids, ['UID', 'BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]']) }.map do |row|
      [row.attr.fetch('UID'), Mail.read_from_string(row.attr.fetch('BODY[HEADER.FIELDS (MESSAGE-ID)]')).message_id]
    end
  end

  [
    [:longer_only, 'Other', ['x123@example.test'], :conflict],
    [:exact_only, 'Archive', [], :already_in_target],
    [:both, 'Archive', ['x123@example.test'], :already_in_target],
    [:unrelated_only, 'Other', ['456@example.test'], :conflict],
    [:duplicate_exact, 'Archive', ['123@example.test'], :conflict]
  ].each do |name, moved_folder, extra_ids, expected_status|
    it "move recovery: #{name}" do
      source_id = '123@example.test'
      append_message('INBOX', source_id)
      session.command { |imap| imap.select('INBOX') }
      validity = client.responses('UIDVALIDITY').last
      uid = session.command { |imap| imap.uid_search(['ALL']) }.sole
      identity = Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: validity, uid: uid, roles: ['inbox'])
      session.command { |imap| imap.uid_move(uid, moved_folder) }
      extra_ids.each { |id| append_message('Archive', id) }
      actual = headers('Archive')
      candidates = session.command { |imap| imap.uid_search(['HEADER', 'MESSAGE-ID', source_id]) }
      expect(candidates).to match_array(actual.select { |_, id| id.include?(source_id) }.map(&:first))
      result = Imap::MailboxCommand::Standard.new(session: session, client: client, targets: { 'archive' => 'Archive' })
                                             .call(action: :archive, identity: identity, message_id: source_id)
      expect(result.status).to eq(expected_status)
      if expected_status == :already_in_target
        expect(result.target_uid).to eq(actual.select { |_, id| id == source_id }.sole.first)
      else
        expect(result.target_uid).to be_nil
      end
      expect(headers('Other').map(&:last)).to eq([source_id]) if moved_folder == 'Other'
      puts({ case: name, path: 'move', candidates: candidates, headers: actual, result: result.to_h }.to_json)
    end
  end

  [
    [:longer_only, 'awaiting_provider_copy'], [:exact_only, 'synced'], [:both, 'synced'],
    [:unrelated_only, 'awaiting_provider_copy'], [:empty, 'awaiting_provider_copy'], [:duplicate_exact, 'conflict']
  ].each do |name, expected_state|
    it "provider-managed Sent: #{name}" do
      account = create(:account)
      account.enable_features!(:email_mailbox_actions)
      channel = create(:channel_email, :imap_email, account: account, smtp_enabled: true,
                                                    mailbox_sync_config: { 'mode' => 'active', 'sent_mode' => 'provider_managed' })
      conversation = create(:conversation, account: account, inbox: channel.inbox,
                                           contact: create(:contact, account: account, email: 'recipient@example.test'))
      message = create(:message, account: account, inbox: channel.inbox, conversation: conversation,
                                 message_type: :outgoing, content: 'Synthetic delivered message')
      source_id = ConversationReplyMailer.with(account: account).email_reply(message).message.message_id
      message.update!(source_id: source_id)
      append_message('Sent', "x#{source_id}") if [:longer_only, :both].include?(name)
      append_message('Sent', source_id) if [:exact_only, :both, :duplicate_exact].include?(name)
      append_message('Sent', source_id) if name == :duplicate_exact
      append_message('Sent', 'unrelated@example.test') if name == :unrelated_only
      actual = headers('Sent')
      candidates = session.command { |imap| imap.uid_search(['HEADER', 'MESSAGE-ID', source_id]) }
      expect(candidates).to match_array(actual.select { |_, id| id.include?(source_id) }.map(&:first))
      mailbox = Imap::SentMailbox.new(client: client, session: session, mailbox: 'Sent', append_allowed: false).examine!
      expect(client).not_to receive(:append)
      report = Imap::SentOutboundSync.new(channel: channel, sent_mailbox: mailbox).perform
      message.reload
      expect(message.imap_sent_sync.state).to eq(expected_state)
      if expected_state == 'synced'
        expect([message.imap_identity.uid, report[:attached]]).to eq([actual.select { |_, id| id == source_id }.sole.first, 1])
      else
        expect([message.imap_identity, report[:attached]]).to eq([nil, 0])
      end
      if name == :longer_only
        retry_report = Imap::SentOutboundSync.new(channel: channel, sent_mailbox: mailbox).perform
        expect([retry_report[:candidates], message.reload.imap_sent_sync.state]).to eq([1, 'awaiting_provider_copy'])
      end
      expect(headers('Sent')).to eq(actual)
      puts({ case: name, path: 'sent', candidates: candidates, headers: actual,
             report: report, state: message.imap_sent_sync.state }.to_json)
    end
  end

  it 'confirms the exact moved UID when COPYUID metadata is unavailable' do
    append_message('INBOX', '123@example.test')
    append_message('Archive', 'x123@example.test')
    session.command { |imap| imap.select('INBOX') }
    identity = Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: client.responses('UIDVALIDITY').last,
                                           uid: session.command { |imap| imap.uid_search(['ALL']) }.sole, roles: ['inbox'])
    # Dovecot supports UIDPLUS. Suppress only the receipt, never MOVE, SEARCH or FETCH.
    allow(client).to receive(:responses).and_call_original
    allow(client).to receive(:responses).with('COPYUID').and_return([])
    result = Imap::MailboxCommand::Standard.new(session: session, client: client, targets: { 'archive' => 'Archive' })
                                           .call(action: :archive, identity: identity, message_id: '123@example.test')
    expect(result.status).to eq(:moved)
    expect(result.target_uid).to eq(headers('Archive').select { |_, id| id == '123@example.test' }.sole.first)
    expect(headers('INBOX')).to be_empty
  end

  [:longer_only, :both, :duplicate_exact].each do |name|
    it "post-APPEND fallback without APPENDUID: #{name}" do
      append_message('Sent', name == :duplicate_exact ? '123@example.test' : 'x123@example.test')
      mailbox = Imap::SentMailbox.new(client: client, session: session, mailbox: 'Sent', append_allowed: true).examine!
      # Execute the actual APPEND but hide its UIDPLUS receipt. All subsequent protocol calls are real.
      allow(client).to receive(:append).and_wrap_original do |original, *args|
        original.call(*args)
        nil
      end
      appended_id = name == :longer_only ? 'unrelated@example.test' : '123@example.test'
      source = Mail.new(message_id: appended_id, body: 'Synthetic fallback fixture').encoded
      result = mailbox.append(source: source, message_id: '123@example.test', internal_date: Time.current)
      actual = headers('Sent')
      expect(actual.map(&:last)).to include(appended_id)
      if name == :both
        expect(result).to eq(uidvalidity: mailbox.uidvalidity, uid: actual.select { |_, id| id == '123@example.test' }.sole.first)
      else
        expect(result).to be_nil
      end
    end
  end
end
