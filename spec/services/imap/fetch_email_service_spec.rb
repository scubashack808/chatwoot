require 'rails_helper'

RSpec.describe Imap::FetchEmailService do
  include ActionMailbox::TestHelper
  let(:logger) { instance_double(ActiveSupport::Logger, info: true, error: true) }
  let(:account) { create(:account) }
  let(:imap_email_channel) { create(:channel_email, :imap_email, account: account) }
  let(:imap) { instance_double(Net::IMAP, disconnected?: false, disconnect: true, capabilities: [], responses: [42]) }
  let(:eml_content_with_message_id) { Rails.root.join('spec/fixtures/files/only_text.eml').read }
  let(:eml_content_without_message_id) { eml_content_with_message_id.sub(/^Message-ID:.*\n/, '') }

  describe '#perform' do
    before do
      allow(Rails).to receive(:logger).and_return(logger)
      allow(Net::IMAP).to receive(:new).with(
        imap_email_channel.imap_address, port: imap_email_channel.imap_port, ssl: imap_email_channel.imap_enable_ssl
      ).and_return(imap)
      allow(imap).to receive(:authenticate).with(
        'plain', imap_email_channel.imap_login, imap_email_channel.imap_password
      )
      allow(imap).to receive(:select).with('INBOX')
    end

    context 'when using CRAM-MD5 authentication' do
      let(:cram_md5_channel) { create(:channel_email, :imap_email, account: account, imap_authentication: 'cram-md5') }

      before do
        allow(Net::IMAP).to receive(:new).with(
          cram_md5_channel.imap_address, port: cram_md5_channel.imap_port, ssl: cram_md5_channel.imap_enable_ssl
        ).and_return(imap)
        allow(imap).to receive(:authenticate).with(
          'CRAM-MD5', cram_md5_channel.imap_login, cram_md5_channel.imap_password
        )
        allow(imap).to receive(:select).with('INBOX')
      end

      it 'uses CRAM-MD5 authentication' do
        travel_to '26.10.2020 10:00'.to_datetime do
          allow(imap).to receive(:uid_search).with(%w[SINCE 25-Oct-2020]).and_return([])
          allow(imap).to receive(:logout)

          described_class.new(channel: cram_md5_channel).perform

          expect(imap).to have_received(:authenticate).with(
            'CRAM-MD5', cram_md5_channel.imap_login, cram_md5_channel.imap_password
          )
        end
      end
    end

    context 'when using LOGIN authentication' do
      let(:login_channel) { create(:channel_email, :imap_email, account: account, imap_authentication: 'login') }

      before do
        allow(Net::IMAP).to receive(:new).with(
          login_channel.imap_address, port: login_channel.imap_port, ssl: login_channel.imap_enable_ssl
        ).and_return(imap)
        allow(imap).to receive(:login).with(
          login_channel.imap_login, login_channel.imap_password
        )
        allow(imap).to receive(:select).with('INBOX')
      end

      it 'uses LOGIN authentication' do
        travel_to '26.10.2020 10:00'.to_datetime do
          allow(imap).to receive(:uid_search).with(%w[SINCE 25-Oct-2020]).and_return([])
          allow(imap).to receive(:logout)

          described_class.new(channel: login_channel).perform

          expect(imap).to have_received(:login).with(
            login_channel.imap_login, login_channel.imap_password
          )
        end
      end
    end

    context 'when new emails are available in the mailbox' do
      it 'fetches the emails and returns the emails that are not present in the db' do
        travel_to '26.10.2020 10:00'.to_datetime do
          email_object = create_inbound_email_from_fixture('only_text.eml')
          email_header = Net::IMAP::FetchData.new(1, 'UID' => 1, 'BODY[HEADER]' => eml_content_with_message_id)
          imap_fetch_mail = Net::IMAP::FetchData.new(1, 'UID' => 1, 'BODY[]' => eml_content_with_message_id)

          allow(imap).to receive(:uid_search).with(%w[SINCE 25-Oct-2020]).and_return([1])
          allow(imap).to receive(:uid_fetch).with([1], ['UID', 'BODY.PEEK[HEADER]']).and_return([email_header])
          allow(imap).to receive(:uid_fetch).with(1, ['BODY.PEEK[]']).and_return([imap_fetch_mail])
          allow(imap).to receive(:logout)

          result = described_class.new(channel: imap_email_channel).perform

          expect(result.length).to eq 1
          expect(result[0].message_id).to eq email_object.message_id
          expect(imap).to have_received(:uid_search).with(%w[SINCE 25-Oct-2020])
          expect(imap).to have_received(:uid_fetch).with([1], ['UID', 'BODY.PEEK[HEADER]'])
          expect(imap).to have_received(:uid_fetch).with(1, ['BODY.PEEK[]'])
          expect(logger).to have_received(:info).with("[IMAP::FETCH_EMAIL_SERVICE] Fetching mails from #{imap_email_channel.email}, found 1.")
          expect(imap).to have_received(:logout)
        end
      end

      it 'fetches the emails and returns the mail objects that are not present in the db' do
        travel_to '26.10.2020 10:00'.to_datetime do
          email_object = create_inbound_email_from_fixture('only_text.eml')
          create(:message, source_id: email_object.message_id, account: account, inbox: imap_email_channel.inbox)

          email_header = Net::IMAP::FetchData.new(1, 'UID' => 1, 'BODY[HEADER]' => eml_content_with_message_id)

          allow(imap).to receive(:uid_search).with(%w[SINCE 25-Oct-2020]).and_return([1])
          allow(imap).to receive(:uid_fetch).with([1], ['UID', 'BODY.PEEK[HEADER]']).and_return([email_header])
          allow(imap).to receive(:logout)

          result = described_class.new(channel: imap_email_channel).perform

          expect(result.length).to eq 0
          expect(imap).to have_received(:uid_search).with(%w[SINCE 25-Oct-2020])
          expect(imap).to have_received(:uid_fetch).with([1], ['UID', 'BODY.PEEK[HEADER]'])
          expect(imap).not_to have_received(:uid_fetch).with(1, ['BODY.PEEK[]'])
        end
      end

      it 'does not return recently deleted emails' do
        travel_to '26.10.2020 10:00'.to_datetime do
          email_object = create_inbound_email_from_fixture('only_text.eml')
          email_header = Net::IMAP::FetchData.new(1, 'UID' => 1, 'BODY[HEADER]' => eml_content_with_message_id)
          redis_key = format(Redis::RedisKeys::IMAP_DELETED_MESSAGE,
                             inbox_id: imap_email_channel.inbox.id,
                             message_id_digest: Digest::SHA256.hexdigest(email_object.message_id))

          Imap::DeletedMessageTracker.new(inbox: imap_email_channel.inbox).record([email_object.message_id])
          allow(imap).to receive(:uid_search).with(%w[SINCE 25-Oct-2020]).and_return([1])
          allow(imap).to receive(:uid_fetch).with([1], ['UID', 'BODY.PEEK[HEADER]']).and_return([email_header])
          allow(imap).to receive(:logout)

          result = described_class.new(channel: imap_email_channel).perform

          expect(result).to be_empty
          expect(imap).not_to have_received(:uid_fetch).with(1, ['BODY.PEEK[]'])
        ensure
          Redis::Alfred.delete(redis_key) if redis_key
        end
      end

      it 'does not count emails without message ids toward the sync limit' do
        travel_to '26.10.2020 10:00'.to_datetime do
          email_object = create_inbound_email_from_fixture('only_text.eml')
          max_messages_per_sync = Imap::BaseFetchEmailService::MAX_MESSAGES_PER_SYNC
          empty_message_id_seq_nums = (1..max_messages_per_sync).to_a
          valid_message_seq_num = max_messages_per_sync + 1
          empty_message_id_headers = empty_message_id_seq_nums.map do |seq_num|
            Net::IMAP::FetchData.new(seq_num, 'UID' => seq_num, 'BODY[HEADER]' => eml_content_without_message_id)
          end
          valid_email_header = Net::IMAP::FetchData.new(valid_message_seq_num, 'UID' => valid_message_seq_num,
                                                                               'BODY[HEADER]' => eml_content_with_message_id)
          imap_fetch_mail = Net::IMAP::FetchData.new(valid_message_seq_num, 'UID' => valid_message_seq_num, 'BODY[]' => eml_content_with_message_id)

          allow(imap).to receive(:uid_search).with(%w[SINCE 25-Oct-2020]).and_return(empty_message_id_seq_nums + [valid_message_seq_num])
          allow(imap).to receive(:uid_fetch).with(empty_message_id_seq_nums, ['UID', 'BODY.PEEK[HEADER]']).and_return(empty_message_id_headers)
          allow(imap).to receive(:uid_fetch).with([valid_message_seq_num], ['UID', 'BODY.PEEK[HEADER]']).and_return([valid_email_header])
          allow(imap).to receive(:uid_fetch).with(valid_message_seq_num, ['BODY.PEEK[]']).and_return([imap_fetch_mail])
          allow(imap).to receive(:logout)

          result = described_class.new(channel: imap_email_channel).perform

          expect(result.length).to eq 1
          expect(result[0].message_id).to eq email_object.message_id
          expect(imap).to have_received(:uid_fetch).with(empty_message_id_seq_nums, ['UID', 'BODY.PEEK[HEADER]'])
          expect(imap).to have_received(:uid_fetch).with([valid_message_seq_num], ['UID', 'BODY.PEEK[HEADER]'])
          expect(imap).to have_received(:uid_fetch).with(valid_message_seq_num, ['BODY.PEEK[]'])
        end
      end
    end
  end

  describe 'connection lifetime and lease' do
    let(:lease_key) { format(Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: imap_email_channel.inbox.id) }

    before do
      allow(Rails).to receive(:logger).and_return(logger)
      allow(Net::IMAP).to receive(:new).with(
        imap_email_channel.imap_address, port: imap_email_channel.imap_port, ssl: imap_email_channel.imap_enable_ssl
      ).and_return(imap)
      allow(imap).to receive(:authenticate)
      allow(imap).to receive(:login)
      allow(imap).to receive(:select).with('INBOX')
      allow(imap).to receive(:logout)
    end

    after { Redis::Alfred.delete(lease_key) }

    it 'closes the socket after a successful fetch instead of leaving it open on logout' do
      allow(imap).to receive(:uid_search).and_return([])

      described_class.new(channel: imap_email_channel).perform

      expect(imap).to have_received(:logout)
      expect(imap).to have_received(:disconnect)
    end

    it 'closes the socket when authentication fails after the connection was established' do
      allow(imap).to receive(:authenticate).and_raise(Net::IMAP::Error, 'bad credentials')

      expect { described_class.new(channel: imap_email_channel).perform }.to raise_error(Net::IMAP::Error, 'bad credentials')

      expect(imap).to have_received(:disconnect)
    end

    it 'closes the socket when mailbox selection fails' do
      allow(imap).to receive(:select).with('INBOX').and_raise(Net::IMAP::Error, 'no such mailbox')

      expect { described_class.new(channel: imap_email_channel).perform }.to raise_error(Net::IMAP::Error, 'no such mailbox')

      expect(imap).to have_received(:disconnect)
    end

    it 'closes the socket when the search fails' do
      allow(imap).to receive(:uid_search).and_raise(IOError, 'connection reset')

      expect { described_class.new(channel: imap_email_channel).perform }.to raise_error(IOError, 'connection reset')

      expect(imap).to have_received(:disconnect)
    end

    it 'releases the lease after a successful fetch' do
      allow(imap).to receive(:uid_search).and_return([])

      described_class.new(channel: imap_email_channel).perform

      expect(Redis::Alfred.exists?(lease_key)).to be false
    end

    it 'releases the lease when the fetch fails' do
      allow(imap).to receive(:uid_search).and_raise(IOError, 'connection reset')

      expect { described_class.new(channel: imap_email_channel).perform }.to raise_error(IOError)

      expect(Redis::Alfred.exists?(lease_key)).to be false
    end

    it 'never opens a second connection while another worker holds the lease' do
      Imap::Lease.new(inbox_id: imap_email_channel.inbox.id, ttl: 30).acquire

      expect { described_class.new(channel: imap_email_channel).perform }
        .to raise_error(Imap::Lease::LeaseNotAcquiredError)

      expect(Net::IMAP).not_to have_received(:new)
    end
  end

  describe 'UID based ingestion' do
    let(:lease_key) { format(Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: imap_email_channel.inbox.id) }
    let(:email_header) { Net::IMAP::FetchData.new(1, 'UID' => 91, 'BODY[HEADER]' => eml_content_with_message_id) }
    let(:imap_fetch_mail) { Net::IMAP::FetchData.new(1, 'UID' => 91, 'BODY[]' => eml_content_with_message_id) }

    before do
      allow(Rails).to receive(:logger).and_return(logger)
      allow(Net::IMAP).to receive(:new).and_return(imap)
      allow(imap).to receive(:authenticate)
      allow(imap).to receive(:login)
      allow(imap).to receive(:select).with('INBOX')
      allow(imap).to receive(:logout)
      allow(imap).to receive(:search)
      allow(imap).to receive(:uid_search).and_return([91])
      allow(imap).to receive(:uid_fetch).with([91], ['UID', 'BODY.PEEK[HEADER]']).and_return([email_header])
      allow(imap).to receive(:uid_fetch).with(91, ['BODY.PEEK[]']).and_return([imap_fetch_mail])
      allow(imap).to receive(:responses).with('UIDVALIDITY').and_return([555])
    end

    after { Redis::Alfred.delete(lease_key) }

    it 'searches and fetches by UID, never by sequence number' do
      described_class.new(channel: imap_email_channel).perform

      expect(imap).to have_received(:uid_search)
      expect(imap).not_to have_received(:search)
    end

    it 'returns fetched messages carrying the server coordinates' do
      result = described_class.new(channel: imap_email_channel).perform

      expect(result.length).to eq 1
      expect(result.first).to be_a(Imap::FetchedMessage)
      expect(result.first.mailbox).to eq 'INBOX'
      expect(result.first.uid).to eq 91
      expect(result.first.uidvalidity).to eq 555
      expect(result.first.roles).to eq ['inbox']
    end

    it 'builds an identity from the fetched message' do
      identity = described_class.new(channel: imap_email_channel).perform.first.to_identity

      expect(identity.uid).to eq 91
      expect(identity.uidvalidity).to eq 555
      expect(identity.mailbox).to eq 'INBOX'
    end

    it 'does not request the Gmail extension on a server that does not advertise it' do
      described_class.new(channel: imap_email_channel).perform

      expect(imap).to have_received(:uid_fetch).with([91], ['UID', 'BODY.PEEK[HEADER]'])
      expect(imap).not_to have_received(:uid_fetch).with([91], ['UID', 'BODY.PEEK[HEADER]', 'X-GM-MSGID'])
    end

    context 'when the server advertises the Gmail extension' do
      let(:email_header) do
        Net::IMAP::FetchData.new(1, 'UID' => 91, 'X-GM-MSGID' => 1_234_567_890, 'BODY[HEADER]' => eml_content_with_message_id)
      end
      let(:imap_fetch_mail) do
        Net::IMAP::FetchData.new(1, 'UID' => 91, 'X-GM-MSGID' => 1_234_567_890, 'BODY[]' => eml_content_with_message_id)
      end

      before do
        allow(imap).to receive(:capabilities).and_return(['X-GM-EXT-1'])
        allow(imap).to receive(:uid_fetch).with([91], ['UID', 'BODY.PEEK[HEADER]', 'X-GM-MSGID']).and_return([email_header])
        allow(imap).to receive(:uid_fetch).with(91, ['BODY.PEEK[]', 'X-GM-MSGID']).and_return([imap_fetch_mail])
      end

      it 'captures the provider stable id' do
        result = described_class.new(channel: imap_email_channel).perform

        expect(result.first.provider_id).to eq '1234567890'
        expect(result.first.to_identity.provider_id).to eq '1234567890'
      end
    end
  end
end
