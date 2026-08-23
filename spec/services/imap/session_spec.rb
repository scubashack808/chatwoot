require 'rails_helper'

RSpec.describe Imap::Session do
  let(:logger) { instance_double(ActiveSupport::Logger, info: true, error: true, warn: true) }
  let(:client) { instance_double(Net::IMAP, disconnected?: false, logout: true, disconnect: true) }

  before { allow(Rails).to receive(:logger).and_return(logger) }

  def run_session(**, &)
    described_class.run(connect_timeout: 5, command_timeout: 5, **, &)
  end

  describe '.run' do
    it 'returns the value of the block' do
      expect(run_session { :done }).to eq :done
    end

    it 'disconnects a connected client on the success path' do
      run_session do |session|
        session.connect { client }
      end

      expect(client).to have_received(:logout)
      expect(client).to have_received(:disconnect)
    end

    it 'does nothing when no client was ever established' do
      expect { run_session { :no_connection } }.not_to raise_error
      expect(client).not_to have_received(:disconnect)
    end
  end

  describe 'cleanup fault matrix' do
    it 'disconnects and preserves the original error when the connect itself fails' do
      expect do
        run_session do |session|
          session.connect { raise Errno::ECONNREFUSED, 'connect refused' }
        end
      end.to raise_error(Errno::ECONNREFUSED, /connect refused/)
    end

    # The leak the inventory describes: Net::IMAP.new succeeds and opens a socket, then
    # authentication raises. The socket must still be closed.
    it 'disconnects the established socket when authentication fails afterwards' do
      expect do
        run_session do |session|
          session.connect { client }
          session.command { raise Net::IMAP::Error, 'auth failed' }
        end
      end.to raise_error(Net::IMAP::Error, 'auth failed')

      expect(client).to have_received(:disconnect)
    end

    it 'disconnects when select fails' do
      expect do
        run_session do |session|
          session.connect { client }
          session.command { raise Net::IMAP::Error, 'no such mailbox' }
        end
      end.to raise_error(Net::IMAP::Error, 'no such mailbox')

      expect(client).to have_received(:disconnect)
    end

    it 'disconnects when a fetch fails' do
      expect do
        run_session do |session|
          session.connect { client }
          session.command { raise IOError, 'fetch exploded' }
        end
      end.to raise_error(IOError, 'fetch exploded')

      expect(client).to have_received(:disconnect)
    end

    it 'still disconnects when logout raises, and does not mask the original error' do
      allow(client).to receive(:logout).and_raise(Net::IMAP::Error, 'logout failed')

      expect do
        run_session do |session|
          session.connect { client }
          raise ArgumentError, 'original failure'
        end
      end.to raise_error(ArgumentError, 'original failure')

      expect(client).to have_received(:disconnect)
    end

    it 'does not mask a successful result when logout raises' do
      allow(client).to receive(:logout).and_raise(Net::IMAP::Error, 'logout failed')

      result = run_session do |session|
        session.connect { client }
        :fetched
      end

      expect(result).to eq :fetched
      expect(client).to have_received(:disconnect)
    end

    it 'never lets a disconnect failure replace the original error' do
      allow(client).to receive(:disconnect).and_raise(IOError, 'socket already dead')

      expect do
        run_session do |session|
          session.connect { client }
          raise ArgumentError, 'original failure'
        end
      end.to raise_error(ArgumentError, 'original failure')
    end

    it 'never lets a disconnect failure escape on the success path' do
      allow(client).to receive(:disconnect).and_raise(IOError, 'socket already dead')

      expect { run_session { |session| session.connect { client } } }.not_to raise_error
    end

    it 'skips logout and disconnect when the client is already disconnected' do
      allow(client).to receive(:disconnected?).and_return(true)

      run_session { |session| session.connect { client } }

      expect(client).not_to have_received(:logout)
      expect(client).not_to have_received(:disconnect)
    end

    it 'closes only once even when close is called explicitly inside the block' do
      run_session do |session|
        session.connect { client }
        session.close
      end

      expect(client).to have_received(:disconnect).once
    end
  end

  describe 'timeouts' do
    it 'bounds the connect with the injected connect timeout' do
      expect do
        described_class.run(connect_timeout: 0.05, command_timeout: 5) do |session|
          session.connect { sleep 1 }
        end
      end.to raise_error(Timeout::Error)
    end

    it 'bounds each command with the injected command timeout and still disconnects' do
      expect do
        described_class.run(connect_timeout: 5, command_timeout: 0.05) do |session|
          session.connect { client }
          session.command { sleep 1 }
        end
      end.to raise_error(Timeout::Error)

      expect(client).to have_received(:disconnect)
    end

    it 'defaults to the mailbox-local 15 second connect and 45 second command bounds' do
      expect(described_class::CONNECT_TIMEOUT_SECONDS).to eq 15
      expect(described_class::COMMAND_TIMEOUT_SECONDS).to eq 45
    end
  end

  describe 'lease integration' do
    let(:lease) { instance_double(Imap::Lease, ensure_held!: true) }

    it 'renews the lease before each command' do
      run_session(lease: lease) do |session|
        session.connect { client }
        session.command { :one }
        session.command { :two }
      end

      # once for the connect, then once before each of the two commands
      expect(lease).to have_received(:ensure_held!).exactly(3).times
    end

    it 'renews the lease before connecting' do
      run_session(lease: lease) { |session| session.connect { client } }

      expect(lease).to have_received(:ensure_held!).once
    end

    it 'stops before running the command when the lease was lost, and still disconnects' do
      calls = 0
      allow(lease).to receive(:ensure_held!) do
        calls += 1
        raise Imap::Lease::LeaseLostError, 'lease lost' if calls > 1

        true
      end
      ran = false

      expect do
        run_session(lease: lease) do |session|
          session.connect { client }
          session.command { ran = true }
        end
      end.to raise_error(Imap::Lease::LeaseLostError)

      expect(ran).to be false
      expect(client).to have_received(:disconnect)
    end

    it 'works without a lease' do
      expect { run_session { |session| session.connect { client } } }.not_to raise_error
    end
  end

  describe '#connected?' do
    it 'is false before connecting and true afterwards' do
      run_session do |session|
        expect(session.connected?).to be false
        session.connect { client }
        expect(session.connected?).to be true
      end
    end

    it 'is false after close' do
      run_session do |session|
        session.connect { client }
        session.close
        expect(session.connected?).to be false
      end
    end
  end
end
