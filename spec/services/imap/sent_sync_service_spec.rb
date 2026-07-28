require 'rails_helper'

# Row 08 of the thin-patch stack: "Synchronize Sent without folder guesses or duplicates."
#
# M05 acceptance oracle: provider-managed mode never APPENDs; append mode captures APPENDUID;
#      rerun deduplicates.
# M06 acceptance oracle: discovered Sent reply threads once by exact references/identity.
#
# The Gmail examples fake the X-GM-EXT-1 capability. That is disclosed rather than claimed away:
# the sandbox cannot speak the real Gmail dialect, and the real non-production Gmail lane is
# Gate D in the execution plan.
RSpec.describe Imap::SentSyncService do
  let(:account) { create(:account) }
  # smtp_enabled matters and was missing. ConversationReplyMailer#email_reply returns early unless
  # the inbox can actually send, so without it the mailer never renders and `rendered_source`
  # produces an unprocessed, header-less mail. Every one of these examples describes an inbox whose
  # Chatwoot replies really did go out over SMTP, which is exactly an inbox with SMTP enabled.
  let(:channel) { create(:channel_email, :imap_email, account: account, smtp_enabled: true, mailbox_sync_config: config) }
  let(:config) { { 'mode' => 'active', 'sent_mode' => 'append' } }
  let(:inbox) { channel.inbox }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: create(:contact, account: account, email: 'customer@example.test'))
  end
  let(:lease_key) { format(Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: inbox.id) }
  let(:capabilities) { %w[IMAP4REV1 UIDPLUS MOVE SPECIAL-USE] }
  let(:folders) do
    [
      Net::IMAP::MailboxList.new([:Haschildren], '.', 'INBOX'),
      Net::IMAP::MailboxList.new([:Sent, :Hasnochildren], '.', 'INBOX.SentItems'),
      Net::IMAP::MailboxList.new([:Trash, :Hasnochildren], '.', 'INBOX.Trash')
    ]
  end
  let(:imap) { instance_double(Net::IMAP, disconnected?: false, disconnect: true, logout: true) }

  # A Chatwoot send that already went out over SMTP. SendOnEmailService stores the RFC Message-ID
  # the mailer actually produced (`message.update(source_id: reply_mail.message_id)`), so in
  # production the stored id and the re-rendered id agree by construction. The fixture is built the
  # same way rather than with a made-up string, because the whole search-before-append guard is
  # only meaningful when those two agree, and a fixture that faked it could not detect the day
  # they stop agreeing.
  let(:outgoing_message) do
    message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing)
    message.update!(source_id: delivered_message_id(message))
    message
  end

  # UIDPLUS APPENDUID as net-imap parses it.
  let(:append_response) do
    tagged_response('APPENDUID', Struct.new(:uidvalidity, :assigned_uid).new(7001, 42))
  end

  # Exactly what SendOnEmailService records at delivery time.
  def delivered_message_id(message)
    ConversationReplyMailer.with(account: message.account).email_reply(message).message.message_id
  end

  # A method rather than a let, deliberately: the M06 group is already at RuboCop's memoized-helper
  # limit, and this needs no memoisation of its own because outgoing_message is already memoised.
  def sent_message_id
    outgoing_message.source_id
  end

  def tagged_response(name, data)
    code = name.nil? ? nil : instance_double(Net::IMAP::ResponseCode, name: name, data: data)
    instance_double(Net::IMAP::TaggedResponse, data: instance_double(Net::IMAP::ResponseText, code: code))
  end

  before do
    # Sent sync is dark twice over, like every other mailbox path in this stack: the account
    # feature flag AND the per-inbox mode. These examples are about what happens once it is on.
    account.enable_features!(:email_mailbox_actions)
    allow(Net::IMAP).to receive(:new).and_return(imap)
    allow(imap).to receive(:authenticate)
    allow(imap).to receive(:login)
    allow(imap).to receive(:select).with('INBOX')
    allow(imap).to receive(:capabilities).and_return(capabilities)
    allow(imap).to receive(:list).with('', '*').and_return(folders)
    allow(imap).to receive(:examine)
    allow(imap).to receive(:responses).with('UIDVALIDITY').and_return([7001])
    allow(imap).to receive(:uid_search).and_return([])
    allow(imap).to receive(:uid_fetch).and_return(nil)
    allow(imap).to receive(:append).and_return(append_response)
  end

  after { Redis::Alfred.delete(lease_key) }

  describe 'folder resolution: no guessing, ever' do
    it 'uses the exact folder the server advertises with the \\Sent special-use attribute' do
      outgoing_message
      report = described_class.new(channel: channel).perform

      expect(report[:mailbox]).to eq 'INBOX.SentItems'
      expect(imap).to have_received(:append).with('INBOX.SentItems', anything, anything, anything)
    end

    it 'refuses to run when the server advertises no Sent folder, rather than guessing a name' do
      outgoing_message
      allow(imap).to receive(:list).with('', '*').and_return([Net::IMAP::MailboxList.new([:Haschildren], '.', 'INBOX')])

      report = described_class.new(channel: channel).perform

      expect(report[:status]).to eq 'skipped'
      expect(report[:reason]).to eq 'sent_folder_unavailable'
      expect(imap).not_to have_received(:append)
    end

    it 'refuses to run when two folders claim \\Sent and no administrator override picks one' do
      outgoing_message
      allow(imap).to receive(:list).with('', '*').and_return(
        folders + [Net::IMAP::MailboxList.new([:Sent, :Hasnochildren], '.', 'INBOX.Sent Messages')]
      )

      report = described_class.new(channel: channel).perform

      expect(report[:status]).to eq 'skipped'
      expect(report[:reason]).to eq 'sent_folder_unavailable'
      expect(report[:detail]).to eq 'ambiguous'
      expect(imap).not_to have_received(:append)
    end

    it 'uses an exact administrator override when discovery is ambiguous' do
      outgoing_message
      channel.update!(mailbox_sync_config: config.merge('folder_overrides' => { 'sent' => 'INBOX.SentItems' }))
      allow(imap).to receive(:list).with('', '*').and_return(
        folders + [Net::IMAP::MailboxList.new([:Sent, :Hasnochildren], '.', 'INBOX.Sent Messages')]
      )

      report = described_class.new(channel: channel).perform

      expect(report[:status]).to eq 'completed'
      expect(report[:mailbox]).to eq 'INBOX.SentItems'
    end
  end

  describe 'append mode (M05)' do
    it 'searches Sent by Message-ID before it appends anything' do
      outgoing_message
      described_class.new(channel: channel).perform

      expect(imap).to have_received(:uid_search).with(['HEADER', 'Message-ID', sent_message_id])
    end

    it 'captures APPENDUID and persists it as the message identity with the sent role' do
      outgoing_message
      report = described_class.new(channel: channel).perform

      identity = outgoing_message.reload.imap_identity
      expect(identity.mailbox).to eq 'INBOX.SentItems'
      expect(identity.uidvalidity).to eq 7001
      expect(identity.uid).to eq 42
      expect(identity.roles).to eq ['sent']
      expect(report[:outbound][:appended]).to eq 1
    end

    it 'records the message as synced so a later cycle does not consider it again' do
      outgoing_message
      described_class.new(channel: channel).perform

      expect(outgoing_message.reload.imap_sent_sync.state).to eq 'synced'
      expect(described_class.new(channel: channel).perform[:outbound][:candidates]).to eq 0
    end

    it 'reads APPENDUID from a server that returns it as a raw string' do
      outgoing_message
      allow(imap).to receive(:append).and_return(tagged_response('APPENDUID', '7001 43'))

      described_class.new(channel: channel).perform

      expect(outgoing_message.reload.imap_identity.uid).to eq 43
    end

    it 'confirms the copy by search when the server returns no APPENDUID' do
      outgoing_message
      allow(imap).to receive(:append).and_return(tagged_response(nil, nil))
      allow(imap).to receive(:uid_search).with(['HEADER', 'Message-ID', sent_message_id]).and_return([], [99])

      described_class.new(channel: channel).perform

      expect(outgoing_message.reload.imap_identity.uid).to eq 99
    end
  end

  describe 'rerun deduplicates (M05)' do
    it 'attaches the existing copy instead of appending a second one' do
      outgoing_message
      allow(imap).to receive(:uid_search).with(['HEADER', 'Message-ID', sent_message_id]).and_return([55])

      report = described_class.new(channel: channel).perform

      expect(imap).not_to have_received(:append)
      expect(report[:outbound][:attached]).to eq 1
      expect(report[:outbound][:appended]).to eq 0
      expect(outgoing_message.reload.imap_identity.uid).to eq 55
    end

    it 'records a conflict rather than appending when the server already holds two copies' do
      outgoing_message
      allow(imap).to receive(:uid_search).with(['HEADER', 'Message-ID', sent_message_id]).and_return([55, 56])

      report = described_class.new(channel: channel).perform

      expect(imap).not_to have_received(:append)
      expect(report[:outbound][:conflict]).to eq 1
      expect(outgoing_message.reload.imap_sent_sync.state).to eq 'conflict'
    end
  end

  describe 'provider-managed mode (M05)' do
    let(:config) { { 'mode' => 'active', 'sent_mode' => 'provider_managed' } }

    it 'never issues an APPEND, and attaches the copy the provider made' do
      outgoing_message
      allow(imap).to receive(:uid_search).with(['HEADER', 'Message-ID', sent_message_id]).and_return([31])

      report = described_class.new(channel: channel).perform

      expect(imap).not_to have_received(:append)
      expect(report[:outbound][:attached]).to eq 1
      expect(outgoing_message.reload.imap_identity.uid).to eq 31
    end

    it 'never issues an APPEND even when the provider copy is not there yet' do
      outgoing_message
      report = described_class.new(channel: channel).perform

      expect(imap).not_to have_received(:append)
      expect(report[:outbound][:awaiting_provider_copy]).to eq 1
      expect(outgoing_message.reload.imap_sent_sync.state).to eq 'awaiting_provider_copy'
    end

    it 'retries the same message on the next cycle rather than abandoning it' do
      outgoing_message
      described_class.new(channel: channel).perform

      expect(described_class.new(channel: channel).perform[:outbound][:candidates]).to eq 1
    end
  end

  describe 'Gmail is selected by capability, never by the provider field' do
    let(:capabilities) { %w[IMAP4REV1 UIDPLUS MOVE SPECIAL-USE X-GM-EXT-1] }
    let(:folders) do
      [
        Net::IMAP::MailboxList.new([:Haschildren], '/', 'INBOX'),
        Net::IMAP::MailboxList.new([:Sent, :Hasnochildren], '/', '[Gmail]/Sent Mail')
      ]
    end

    it 'never APPENDs on a server advertising X-GM-EXT-1 even when append mode is configured' do
      outgoing_message
      expect(channel.provider).to be_blank

      report = described_class.new(channel: channel).perform

      expect(imap).not_to have_received(:append)
      expect(report[:gmail]).to be true
      expect(report[:effective_sent_mode]).to eq 'provider_managed'
    end

    it 'attaches the copy Gmail SMTP already saved' do
      outgoing_message
      allow(imap).to receive(:uid_search).with(['HEADER', 'Message-ID', sent_message_id]).and_return([12])

      described_class.new(channel: channel).perform

      identity = outgoing_message.reload.imap_identity
      expect(identity.mailbox).to eq '[Gmail]/Sent Mail'
      expect(identity.uid).to eq 12
    end
  end

  describe 'modes that do no work at all' do
    it 'does nothing when sent_mode is disabled' do
      outgoing_message
      channel.update!(mailbox_sync_config: config.merge('sent_mode' => 'disabled'))

      report = described_class.new(channel: channel).perform

      expect(report[:status]).to eq 'skipped'
      expect(report[:reason]).to eq 'sent_sync_disabled'
      expect(Net::IMAP).not_to have_received(:new)
    end

    it 'does nothing when the inbox mailbox sync mode is off' do
      outgoing_message
      channel.update!(mailbox_sync_config: config.merge('mode' => 'off'))

      report = described_class.new(channel: channel).perform

      expect(report[:status]).to eq 'skipped'
      expect(report[:reason]).to eq 'mailbox_sync_off'
      expect(Net::IMAP).not_to have_received(:new)
    end

    it 'runs in observe mode, because attaching an existing copy mutates nothing on the server' do
      outgoing_message
      channel.update!(mailbox_sync_config: config.merge('mode' => 'observe'))
      allow(imap).to receive(:uid_search).with(['HEADER', 'Message-ID', sent_message_id]).and_return([55])

      report = described_class.new(channel: channel).perform

      expect(report[:status]).to eq 'completed'
      expect(report[:outbound][:attached]).to eq 1
    end

    it 'never APPENDs in observe mode, because APPEND is a provider mutation' do
      outgoing_message
      channel.update!(mailbox_sync_config: config.merge('mode' => 'observe'))

      report = described_class.new(channel: channel).perform

      expect(imap).not_to have_received(:append)
      expect(report[:effective_sent_mode]).to eq 'provider_managed'
    end
  end

  describe 'failure honesty (M05)' do
    it 'records an APPEND failure as visible state and retries it on the next cycle' do
      outgoing_message
      allow(imap).to receive(:append).and_raise(Net::IMAP::NoResponseError.new(instance_double(Net::IMAP::TaggedResponse,
                                                                                               data: instance_double(Net::IMAP::ResponseText,
                                                                                                                     text: 'Over quota'))))

      report = described_class.new(channel: channel).perform

      expect(report[:outbound][:failed]).to eq 1
      state = outgoing_message.reload.imap_sent_sync
      expect(state.state).to eq 'failed'
      expect(state.attempts).to eq 1
      expect(state.error).to be_present
      expect(described_class.new(channel: channel).perform[:outbound][:candidates]).to eq 1
    end

    it 'never marks the Chatwoot message itself as failed to deliver' do
      outgoing_message
      allow(imap).to receive(:append).and_raise(IOError, 'connection reset')

      described_class.new(channel: channel).perform

      expect(outgoing_message.reload.status).to eq 'sent'
    end

    it 'defers instead of opening a second connection when another worker holds the lease' do
      outgoing_message
      Imap::Lease.new(inbox_id: inbox.id, ttl: 30).acquire

      expect { described_class.new(channel: channel).perform }.to raise_error(Imap::Lease::LeaseNotAcquiredError)
    end
  end

  describe 'importing external Sent replies (M06)' do
    let(:external_uid) { 900 }
    let(:external_message_id) { 'sent-from-phone@example.test' }
    let(:external_raw) do
      <<~MAIL
        From: care@example.test
        To: customer@example.test
        Subject: Re: dive booking
        Message-ID: <#{external_message_id}>
        In-Reply-To: <customer-original@example.test>
        References: <customer-original@example.test>
        Content-Type: text/plain

        Replied from my phone.
      MAIL
    end

    before do
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, source_id: 'customer-original@example.test')
      allow(imap).to receive(:uid_search).with(array_including('SINCE')).and_return([external_uid])
      allow(imap).to receive(:uid_fetch).with([external_uid], array_including('BODY.PEEK[HEADER]')).and_return(
        [instance_double(Net::IMAP::FetchData, attr: { 'UID' => external_uid, 'BODY[HEADER]' => external_raw })]
      )
      allow(imap).to receive(:uid_fetch).with(external_uid, array_including('BODY.PEEK[]')).and_return(
        [instance_double(Net::IMAP::FetchData, attr: { 'UID' => external_uid, 'BODY[]' => external_raw })]
      )
    end

    it 'imports the reply into the conversation it references, as an outgoing message' do
      report = described_class.new(channel: channel).perform

      imported = conversation.messages.find_by(source_id: external_message_id)
      expect(imported).to be_present
      expect(imported.message_type).to eq 'outgoing'
      expect(report[:inbound][:imported]).to eq 1
    end

    it 'records the Sent identity so the message is tracked by UID, not by Message-ID alone' do
      described_class.new(channel: channel).perform

      identity = conversation.messages.find_by(source_id: external_message_id).imap_identity
      expect(identity.mailbox).to eq 'INBOX.SentItems'
      expect(identity.uid).to eq external_uid
      expect(identity.roles).to eq ['sent']
    end

    it 'imports it exactly once across repeated cycles' do
      described_class.new(channel: channel).perform
      described_class.new(channel: channel).perform

      expect(conversation.messages.where(source_id: external_message_id).count).to eq 1
    end

    it 'creates no contact and no conversation for an unthreaded external message' do
      unthreaded = "From: care@example.test\nTo: stranger@example.test\nSubject: cold\nMessage-ID: <cold@example.test>\n\n"
      allow(imap).to receive(:uid_fetch).with([external_uid], array_including('BODY.PEEK[HEADER]')).and_return(
        [instance_double(Net::IMAP::FetchData, attr: { 'UID' => external_uid, 'BODY[HEADER]' => unthreaded })]
      )

      expect { described_class.new(channel: channel).perform }
        .to not_change(Conversation, :count)
        .and not_change(Contact, :count)
        .and not_change(Message, :count)
    end

    it 'reports the unthreaded message rather than silently dropping it' do
      allow(imap).to receive(:uid_fetch).with([external_uid], array_including('BODY.PEEK[HEADER]')).and_return(
        [instance_double(Net::IMAP::FetchData,
                         attr: { 'UID' => external_uid,
                                 'BODY[HEADER]' => "From: care@example.test\nSubject: cold\nMessage-ID: <cold@example.test>\n\n" })]
      )

      expect(described_class.new(channel: channel).perform[:inbound][:unthreaded]).to eq 1
    end

    it 'does not re-import a Chatwoot send that is already in the conversation' do
      outgoing_message
      allow(imap).to receive(:uid_fetch).with([external_uid], array_including('BODY.PEEK[HEADER]')).and_return(
        [instance_double(Net::IMAP::FetchData,
                         attr: { 'UID' => external_uid,
                                 'BODY[HEADER]' => "From: care@example.test\nSubject: ours\nMessage-ID: <#{sent_message_id}>\n\n" })]
      )

      report = described_class.new(channel: channel).perform

      expect(report[:inbound][:imported]).to eq 0
      expect(report[:inbound][:already_present]).to eq 1
    end

    # F4. Imap::Session#command renews the lease before every command, so a lost lease surfaces
    # here as an exception. The blanket rescue used to swallow it and count it as a per-message
    # import failure, which records contention as a data failure.
    it 'lets a lost lease propagate out of the import pass rather than counting it as a failure' do
      allow(imap).to receive(:uid_fetch).with(external_uid, array_including('BODY.PEEK[]')).and_raise(Imap::Lease::LeaseLostError)

      expect { described_class.new(channel: channel).perform }.to raise_error(Imap::Lease::LeaseLostError)
      expect(conversation.messages.find_by(source_id: external_message_id)).to be_nil
    end
  end

  # F1. Every other mailbox path in this stack is dark twice over. This one checked only the
  # per-inbox half, so an inbox admin could turn on Active plus Append from an un-gated settings
  # UI and start APPENDing to a real mail server with the account feature flag off.
  describe 'the email_mailbox_actions account gate (F1)' do
    it 'does no Sent work at all when the account feature flag is off' do
      outgoing_message
      account.disable_features!(:email_mailbox_actions)

      report = described_class.new(channel: channel).perform

      expect(report[:status]).to eq 'skipped'
      expect(report[:reason]).to eq 'feature_disabled'
      expect(Net::IMAP).not_to have_received(:new)
    end

    it 'checks the account flag before the per-inbox mode, matching reconciliation ordering' do
      outgoing_message
      account.disable_features!(:email_mailbox_actions)
      channel.update!(mailbox_sync_config: config.merge('mode' => 'off'))

      expect(described_class.new(channel: channel).perform[:reason]).to eq 'feature_disabled'
    end
  end

  # F3. The no-duplicates claim rests entirely on the re-rendered source carrying the same
  # Message-ID the search looks for. Two inputs to that id are mutable after delivery, and nothing
  # read the id back out of the source it was about to send.
  describe 'idempotency backstop (F3)' do
    it 'never APPENDs when the re-rendered source carries a different Message-ID' do
      outgoing_message
      account.update!(domain: 'changed.example.test')

      report = described_class.new(channel: channel).perform

      expect(imap).not_to have_received(:append)
      expect(report[:outbound][:message_id_mismatch]).to eq 1
      expect(outgoing_message.reload.imap_sent_sync.state).to eq 'abandoned'
    end

    it 'does not retry a mismatched message on the next cycle' do
      outgoing_message
      account.update!(domain: 'changed.example.test')
      described_class.new(channel: channel).perform

      expect(described_class.new(channel: channel).perform[:outbound][:candidates]).to eq 0
    end

    it 'stops appending after five consecutive failures rather than retrying for seven days' do
      outgoing_message
      outgoing_message.write_imap_sent_sync!(Imap::SentSyncState.build(state: Imap::SentSyncState::FAILED, attempts: 5))

      report = described_class.new(channel: channel).perform

      expect(imap).not_to have_received(:append)
      expect(report[:outbound][:attempts_exhausted]).to eq 1
      expect(outgoing_message.reload.imap_sent_sync.state).to eq 'abandoned'
    end

    it 'still retries a message that has failed fewer times than the cap' do
      outgoing_message
      outgoing_message.write_imap_sent_sync!(Imap::SentSyncState.build(state: Imap::SentSyncState::FAILED, attempts: 4))

      described_class.new(channel: channel).perform

      expect(imap).to have_received(:append)
    end

    # N1. A mail that did not render at all is not the same thing as one that rendered with the
    # wrong id. ConversationReplyMailer#email_reply returns early, giving a NullMail with no
    # Message-ID, whenever the inbox cannot currently send. That is a misconfiguration a human can
    # undo, and abandoning it would permanently drop the entire backlog in one cycle.
    it 'treats a mail that could not be rendered as a transient failure, not a permanent abandonment' do
      outgoing_message
      channel.update!(smtp_enabled: false)

      report = described_class.new(channel: channel).perform

      expect(imap).not_to have_received(:append)
      expect(report[:outbound][:failed]).to eq 1
      expect(outgoing_message.reload.imap_sent_sync.state).to eq 'failed'
    end

    it 'recovers an unrenderable message once the inbox can send again' do
      outgoing_message
      channel.update!(smtp_enabled: false)
      described_class.new(channel: channel).perform

      channel.update!(smtp_enabled: true)
      report = described_class.new(channel: channel).perform

      expect(report[:outbound][:appended]).to eq 1
      expect(outgoing_message.reload.imap_sent_sync.state).to eq 'synced'
    end
  end

  # F4, the outbound half. See the import half inside the M06 block above.
  describe 'lease loss propagates (F4)' do
    it 'raises out of the outbound pass instead of recording a per-message Sent failure' do
      outgoing_message
      allow(imap).to receive(:uid_search).with(['HEADER', 'Message-ID', sent_message_id]).and_raise(Imap::Lease::LeaseLostError)

      expect { described_class.new(channel: channel).perform }.to raise_error(Imap::Lease::LeaseLostError)
      expect(outgoing_message.reload.imap_sent_sync).to be_nil
    end
  end

  # F6. Imap::Session#command is the only path that renews the lease and applies the command
  # timeout. CAPABILITY decides whether APPEND is allowed at all, so it is the last command that
  # should be issued outside that invariant.
  describe 'capabilities are read inside the session (F6)' do
    it 'passes the session-read capabilities to the dialect selector instead of re-fetching them' do
      outgoing_message
      allow(Imap::MailboxCommand).to receive(:dialect_for).and_call_original

      described_class.new(channel: channel).perform

      expect(Imap::MailboxCommand).to have_received(:dialect_for).with(anything, capabilities: capabilities)
    end
  end
end
