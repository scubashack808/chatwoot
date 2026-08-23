require 'rails_helper'

RSpec.describe Imap::MailboxCommand do
  # net-imap 0.5 gates Net::IMAP::UIDPlusData behind a deprecation flag, and the parser may return
  # either UIDPlusData or CopyUIDData. Both expose uidvalidity and assigned_uids, which is all the
  # command reads, so this stand-in matches either. The real object is exercised in the sandbox.
  let(:client) { instance_double(Net::IMAP) }
  let(:session) { instance_double(Imap::Session) }
  let(:copy_uid_data) do
    Struct.new(:uidvalidity, :source_uids, :assigned_uids).new(
      99,
      Net::IMAP::SequenceSet['7'],
      Net::IMAP::SequenceSet['21']
    )
  end
  let(:identity) { Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox']) }

  before do
    allow(session).to receive(:command).and_yield(client)
    allow(client).to receive(:capabilities).and_return(%w[MOVE UIDPLUS])
    allow(client).to receive(:select)
    allow(client).to receive(:responses).with('UIDVALIDITY').and_return([42])
    allow(client).to receive(:clear_responses)
    allow(client).to receive(:uid_search).and_return([7])
    allow(client).to receive(:uid_move)
    allow(client).to receive(:responses).with('COPYUID').and_return([copy_uid_data])
  end

  def run(action, dialect: described_class::Standard, targets: { 'archive' => 'INBOX.Archive', 'trash' => 'INBOX.Trash', 'spam' => 'INBOX.spam' })
    dialect.new(session: session, client: client, targets: targets).call(action: action, identity: identity)
  end

  describe 'standard IMAP dialect' do
    it 'moves by UID to the configured archive mailbox' do
      result = run(:archive)

      expect(client).to have_received(:uid_move).with(7, 'INBOX.Archive')
      expect(result.status).to eq :moved
    end

    it 'consumes COPYUID to learn the confirmed target identity' do
      result = run(:archive)

      expect(result.target_mailbox).to eq 'INBOX.Archive'
      expect(result.target_uidvalidity).to eq 99
      expect(result.target_uid).to eq 21
    end

    it 'moves to the trash mailbox for trash' do
      run(:trash)

      expect(client).to have_received(:uid_move).with(7, 'INBOX.Trash')
    end

    it 'moves to the spam mailbox for spam' do
      run(:spam)

      expect(client).to have_received(:uid_move).with(7, 'INBOX.spam')
    end

    it 'restores to INBOX, which is never guessed from attributes' do
      archived = Imap::MessageIdentity.build(mailbox: 'INBOX.Archive', uidvalidity: 42, uid: 7)
      described_class::Standard.new(session: session, client: client, targets: {})
                               .call(action: :restore, identity: archived)

      expect(client).to have_received(:uid_move).with(7, 'INBOX')
    end

    it 'selects the mailbox the message currently lives in, not a guess' do
      run(:archive)

      expect(client).to have_received(:select).with('INBOX')
    end

    it 'clears stale COPYUID before issuing the move so it cannot read another command result' do
      run(:archive)

      expect(client).to have_received(:clear_responses).with('COPYUID')
    end

    it 'never issues a sequence number command' do
      expect(client).not_to receive(:move)
      expect(client).not_to receive(:copy)
      expect(client).not_to receive(:store)

      run(:archive)
    end

    it 'refuses a server without MOVE and never falls back to COPY, STORE, or EXPUNGE' do
      allow(client).to receive(:capabilities).and_return(['UIDPLUS'])
      expect(client).not_to receive(:uid_copy)
      expect(client).not_to receive(:uid_store)
      expect(client).not_to receive(:expunge)

      result = run(:archive)

      expect(result.status).to eq :conflict
      expect(result.detail).to match(/UID MOVE/)
      expect(client).not_to have_received(:uid_move)
    end
  end

  describe 'refusing to act on a stale identity' do
    it 'refuses when the mailbox UIDVALIDITY no longer matches the stored identity' do
      allow(client).to receive(:responses).with('UIDVALIDITY').and_return([43])

      result = run(:archive)

      expect(result.status).to eq :conflict
      expect(result.detail).to match(/uidvalidity/i)
      expect(client).not_to have_received(:uid_move)
    end

    it 'refuses when the UID is no longer present, meaning another client already moved it' do
      allow(client).to receive(:uid_search).and_return([])

      result = run(:archive)

      expect(result.status).to eq :conflict
      expect(result.detail).to match(/no longer/i)
      expect(client).not_to have_received(:uid_move)
    end
  end

  describe 'idempotence' do
    it 'treats a message already in the target as success without moving it again' do
      archived = Imap::MessageIdentity.build(mailbox: 'INBOX.Archive', uidvalidity: 42, uid: 7)
      result = described_class::Standard
               .new(session: session, client: client, targets: { 'archive' => 'INBOX.Archive' })
               .call(action: :archive, identity: archived)

      expect(result.status).to eq :already_in_target
      expect(client).not_to have_received(:uid_move)
    end

    it 'treats a concurrent same-target move as idempotent success without moving twice' do
      selected_mailbox = nil
      allow(client).to receive(:select) { |mailbox| selected_mailbox = mailbox }
      allow(client).to receive(:responses).with('UIDVALIDITY') { selected_mailbox == 'INBOX.Archive' ? [99] : [42] }
      allow(client).to receive(:uid_search) do |query|
        selected_mailbox == 'INBOX.Archive' && query == ['HEADER', 'MESSAGE-ID', 'abc@example.com'] ? [31] : []
      end

      result = described_class::Standard
               .new(session: session, client: client, targets: { 'archive' => 'INBOX.Archive' })
               .call(action: :archive, identity: identity, message_id: 'abc@example.com')

      expect(result.status).to eq :already_in_target
      expect(result.target_mailbox).to eq 'INBOX.Archive'
      expect(result.target_uidvalidity).to eq 99
      expect(result.target_uid).to eq 31
      expect(client).not_to have_received(:uid_move)
    end
  end

  describe 'a server that advertises UIDPLUS but omits COPYUID' do
    before { allow(client).to receive(:responses).with('COPYUID').and_return([]) }

    it 'confirms one unique target by stable identity' do
      allow(client).to receive(:uid_search).with(['HEADER', 'MESSAGE-ID', 'abc@example.com']).and_return([31])

      result = described_class::Standard
               .new(session: session, client: client, targets: { 'archive' => 'INBOX.Archive' })
               .call(action: :archive, identity: identity, message_id: 'abc@example.com')

      expect(result.status).to eq :moved
      expect(result.target_uid).to eq 31
    end

    it 'records a conflict when the target cannot be confirmed uniquely' do
      allow(client).to receive(:uid_search).with(['HEADER', 'MESSAGE-ID', 'abc@example.com']).and_return([31, 32])

      result = described_class::Standard
               .new(session: session, client: client, targets: { 'archive' => 'INBOX.Archive' })
               .call(action: :archive, identity: identity, message_id: 'abc@example.com')

      expect(result.status).to eq :conflict
    end
  end

  describe 'an unconfigured target role' do
    it 'refuses rather than guessing a folder' do
      result = described_class::Standard.new(session: session, client: client, targets: {})
                                        .call(action: :archive, identity: identity)

      expect(result.status).to eq :conflict
      expect(result.detail).to match(/not configured/i)
      expect(client).not_to have_received(:uid_move)
    end
  end

  describe 'gmail dialect' do
    subject(:gmail) { described_class::Gmail.new(session: session, client: client, targets: targets) }

    let(:targets) do
      { 'all' => '[Gmail]/All Mail', 'trash' => '[Gmail]/Trash', 'spam' => '[Gmail]/Spam' }
    end

    before do
      allow(client).to receive(:capabilities).and_return(%w[X-GM-EXT-1 MOVE UIDPLUS])
      allow(client).to receive(:uid_store)
    end

    # Archiving on Gmail removes the Inbox label. It is not a move into All Mail.
    it 'archives by removing only the Inbox label' do
      gmail_identity = Imap::MessageIdentity.build(
        mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'], provider_id: '9001'
      )
      allow(client).to receive(:responses).with('UIDVALIDITY').and_return([42], [99])
      allow(client).to receive(:uid_search).with(%w[X-GM-MSGID 9001]).and_return([31])

      result = gmail.call(action: :archive, identity: gmail_identity)

      expect(client).to have_received(:uid_store).with(7, '-X-GM-LABELS', ['\\Inbox'])
      expect(client).not_to have_received(:uid_move)
      expect(result.status).to eq :moved
      expect(result.target_mailbox).to eq '[Gmail]/All Mail'
      expect(result.target_uidvalidity).to eq 99
      expect(result.target_uid).to eq 31
    end

    it 'preserves unrelated labels by touching only the Inbox label' do
      gmail_identity = Imap::MessageIdentity.build(
        mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'], provider_id: '9001'
      )
      allow(client).to receive(:uid_search).with(%w[X-GM-MSGID 9001]).and_return([31])

      gmail.call(action: :archive, identity: gmail_identity)

      expect(client).to have_received(:uid_store).with(7, '-X-GM-LABELS', ['\\Inbox'])
      expect(client).not_to have_received(:uid_store).with(7, 'X-GM-LABELS', anything)
    end

    it 'archives from the frozen Inbox location when All Mail is the identity primary' do
      gmail_identity = Imap::MessageIdentity
                       .build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'], provider_id: '9001')
                       .with_location(mailbox: '[Gmail]/All Mail', uidvalidity: 99, uid: 31, roles: ['archive'])
      allow(client).to receive(:responses).with('UIDVALIDITY').and_return([42], [99])
      allow(client).to receive(:uid_search).with(%w[X-GM-MSGID 9001]).and_return([31])

      gmail.call(action: :archive, identity: gmail_identity, source: gmail_identity.location_for('INBOX'))

      expect(client).to have_received(:uid_store).with(7, '-X-GM-LABELS', ['\\Inbox'])
    end

    it 'reports the message as still present but no longer in Inbox' do
      gmail_identity = Imap::MessageIdentity.build(
        mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox'], provider_id: '9001'
      )
      allow(client).to receive(:uid_search).with(%w[X-GM-MSGID 9001]).and_return([31])

      result = gmail.call(action: :archive, identity: gmail_identity)

      expect(result.target_mailbox).to eq '[Gmail]/All Mail'
      expect(result.detail).to match(/inbox label/i)
    end

    it 'restores by adding the Inbox label back and confirms the new Inbox identity' do
      archived_identity = Imap::MessageIdentity.build(
        mailbox: '[Gmail]/All Mail', uidvalidity: 42, uid: 31, roles: ['archive'], provider_id: '9001'
      )
      allow(client).to receive(:uid_search).with(['UID', 31]).and_return([31])
      allow(client).to receive(:uid_search).with(%w[X-GM-MSGID 9001]).and_return([44])
      allow(client).to receive(:responses).with('UIDVALIDITY').and_return([42], [100])

      result = gmail.call(action: :restore, identity: archived_identity)

      expect(client).to have_received(:uid_store).with(31, '+X-GM-LABELS', ['\\Inbox'])
      expect(result.target_mailbox).to eq 'INBOX'
      expect(result.target_uidvalidity).to eq 100
      expect(result.target_uid).to eq 44
    end

    it 'restores from Gmail Trash with UID MOVE instead of retaining the Trash label' do
      trashed_identity = Imap::MessageIdentity.build(
        mailbox: '[Gmail]/Trash', uidvalidity: 42, uid: 31, roles: ['trash'], provider_id: '9001'
      )
      allow(client).to receive(:uid_search).with(['UID', 31]).and_return([31])

      gmail.call(action: :restore, identity: trashed_identity)

      expect(client).to have_received(:uid_move).with(31, 'INBOX')
      expect(client).not_to have_received(:uid_store)
    end

    it 'refuses archive before mutation when Gmail All Mail cannot be resolved' do
      gmail = described_class::Gmail.new(session: session, client: client, targets: {})

      result = gmail.call(action: :archive, identity: identity, message_id: 'abc@example.com')

      expect(result.status).to eq :conflict
      expect(client).not_to have_received(:uid_store)
    end

    it 'still uses an ordinary UID move for trash' do
      gmail.call(action: :trash, identity: identity)

      expect(client).to have_received(:uid_move).with(7, '[Gmail]/Trash')
    end

    it 'still uses an ordinary UID move for spam' do
      gmail.call(action: :spam, identity: identity)

      expect(client).to have_received(:uid_move).with(7, '[Gmail]/Spam')
    end

    it 'refuses a stale identity exactly like the standard dialect' do
      allow(client).to receive(:responses).with('UIDVALIDITY').and_return([43])

      expect(gmail.call(action: :archive, identity: identity).status).to eq :conflict
      expect(client).not_to have_received(:uid_store)
    end
  end

  describe '.dialect_for' do
    it 'selects the Gmail dialect from the advertised capability, never from the provider field' do
      allow(client).to receive(:capabilities).and_return(['X-GM-EXT-1'])

      expect(described_class.dialect_for(client)).to eq described_class::Gmail
    end

    it 'selects the standard dialect otherwise' do
      allow(client).to receive(:capabilities).and_return(%w[MOVE UIDPLUS])

      expect(described_class.dialect_for(client)).to eq described_class::Standard
    end
  end
end
