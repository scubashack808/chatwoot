require 'rails_helper'

RSpec.describe Imap::MailboxCommand do
  # net-imap 0.5 gates Net::IMAP::UIDPlusData behind a deprecation flag, and the parser may return
  # either UIDPlusData or CopyUIDData. Both expose uidvalidity and assigned_uids, which is all the
  # command reads, so this stand-in matches either. The real object is exercised in the sandbox.
  copy_uid = Struct.new(:uidvalidity, :source_uids, :assigned_uids)
  CopyUidStandIn = copy_uid unless defined?(CopyUidStandIn)

  let(:client) { instance_double(Net::IMAP) }
  let(:session) { instance_double(Imap::Session) }
  let(:identity) { Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 7, roles: ['inbox']) }

  before do
    allow(session).to receive(:command) { |&block| block.call(client) }
    allow(client).to receive(:select)
    allow(client).to receive(:responses).with('UIDVALIDITY').and_return([42])
    allow(client).to receive(:clear_responses)
    allow(client).to receive(:uid_search).and_return([7])
    allow(client).to receive(:uid_move)
    allow(client).to receive(:responses).with('COPYUID')
      .and_return([CopyUidStandIn.new(99, [7], [21])])
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

    let(:targets) { { 'trash' => '[Gmail]/Trash', 'spam' => '[Gmail]/Spam' } }

    before { allow(client).to receive(:uid_store) }

    # Archiving on Gmail removes the Inbox label. It is not a move into All Mail.
    it 'archives by removing only the Inbox label' do
      result = gmail.call(action: :archive, identity: identity)

      expect(client).to have_received(:uid_store).with(7, '-X-GM-LABELS', ['\\Inbox'])
      expect(client).not_to have_received(:uid_move)
      expect(result.status).to eq :moved
    end

    it 'preserves unrelated labels by touching only the Inbox label' do
      gmail.call(action: :archive, identity: identity)

      expect(client).to have_received(:uid_store).with(7, '-X-GM-LABELS', ['\\Inbox'])
      expect(client).not_to have_received(:uid_store).with(7, 'X-GM-LABELS', anything)
    end

    it 'reports the message as still present but no longer in Inbox' do
      result = gmail.call(action: :archive, identity: identity)

      expect(result.target_mailbox).to be_nil
      expect(result.detail).to match(/inbox label/i)
    end

    it 'restores by adding the Inbox label back' do
      gmail.call(action: :restore, identity: identity)

      expect(client).to have_received(:uid_store).with(7, '+X-GM-LABELS', ['\\Inbox'])
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
