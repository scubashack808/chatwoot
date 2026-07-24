require 'rails_helper'

RSpec.describe Imap::Lease do
  let(:inbox_id) { 4321 }
  let(:key) { format(Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: inbox_id) }

  after { Redis::Alfred.delete(key) }

  describe '#initialize' do
    it 'derives the per-inbox key and mints a unique owner token' do
      lease = described_class.new(inbox_id: inbox_id)

      expect(lease.key).to eq key
      expect(lease.token).to be_present
      expect(lease.token).not_to eq described_class.new(inbox_id: inbox_id).token
    end

    it 'defaults to the mailbox-local 120 second lease' do
      expect(described_class.new(inbox_id: inbox_id).ttl).to eq 120
    end

    it 'accepts an injected ttl so tests can use shorter values' do
      expect(described_class.new(inbox_id: inbox_id, ttl: 2).ttl).to eq 2
    end
  end

  describe '#acquire' do
    it 'acquires an unheld lease and records the owner token with a ttl' do
      lease = described_class.new(inbox_id: inbox_id, ttl: 30)

      expect(lease.acquire).to be true
      expect(Redis::Alfred.get(key)).to eq lease.token
      expect(Redis::Alfred.ttl(key)).to be_between(1, 30)
    end

    it 'refuses to acquire while another owner holds the lease' do
      described_class.new(inbox_id: inbox_id, ttl: 30).acquire

      expect(described_class.new(inbox_id: inbox_id, ttl: 30).acquire).to be false
    end

    it 'never opens a second lease for the same inbox' do
      first = described_class.new(inbox_id: inbox_id, ttl: 30)
      first.acquire

      expect(described_class.new(inbox_id: inbox_id).acquire).to be false
      expect(Redis::Alfred.get(key)).to eq first.token
    end

    it 'allows a new owner once the previous lease has expired' do
      described_class.new(inbox_id: inbox_id, ttl: 1).acquire
      sleep 1.5

      expect(described_class.new(inbox_id: inbox_id, ttl: 30).acquire).to be true
    end
  end

  describe '#held?' do
    it 'is true only for the owner token' do
      lease = described_class.new(inbox_id: inbox_id, ttl: 30)
      lease.acquire

      expect(lease.held?).to be true
      expect(described_class.new(inbox_id: inbox_id).held?).to be false
    end

    it 'is false once the lease is gone' do
      lease = described_class.new(inbox_id: inbox_id, ttl: 30)
      lease.acquire
      Redis::Alfred.delete(key)

      expect(lease.held?).to be false
    end
  end

  describe '#renew' do
    it 'extends the lease while the owner token still matches' do
      lease = described_class.new(inbox_id: inbox_id, ttl: 30)
      lease.acquire
      Redis::Alfred.expire(key, 2)

      expect(lease.renew).to be true
      expect(Redis::Alfred.ttl(key)).to be > 2
    end

    it 'refuses to renew a lease owned by a newer worker' do
      lease = described_class.new(inbox_id: inbox_id, ttl: 30)
      lease.acquire
      newer = described_class.new(inbox_id: inbox_id, ttl: 30)
      Redis::Alfred.set(key, newer.token, ex: 30)

      expect(lease.renew).to be false
      expect(Redis::Alfred.get(key)).to eq newer.token
    end

    it 'refuses to renew an expired lease and does not resurrect the key' do
      lease = described_class.new(inbox_id: inbox_id, ttl: 30)
      lease.acquire
      Redis::Alfred.delete(key)

      expect(lease.renew).to be false
      expect(Redis::Alfred.exists?(key)).to be false
    end
  end

  describe '#release' do
    it 'releases a lease it still owns' do
      lease = described_class.new(inbox_id: inbox_id, ttl: 30)
      lease.acquire

      expect(lease.release).to be true
      expect(Redis::Alfred.exists?(key)).to be false
    end

    # This is the exact defect in Redis::LockManager#unlock that this lease exists to avoid.
    it 'never deletes a newer worker lease after its own expiry' do
      stale = described_class.new(inbox_id: inbox_id, ttl: 30)
      stale.acquire
      Redis::Alfred.delete(key)
      newer = described_class.new(inbox_id: inbox_id, ttl: 30)
      newer.acquire

      expect(stale.release).to be false
      expect(Redis::Alfred.get(key)).to eq newer.token
      expect(newer.held?).to be true
    end

    it 'is safe to call when the lease was never acquired' do
      expect(described_class.new(inbox_id: inbox_id).release).to be false
    end
  end

  describe '#ensure_held!' do
    it 'renews and returns true while the lease is owned' do
      lease = described_class.new(inbox_id: inbox_id, ttl: 30)
      lease.acquire

      expect(lease.ensure_held!).to be true
    end

    it 'raises LeaseLostError when the lease expired, stopping work before the next command' do
      lease = described_class.new(inbox_id: inbox_id, ttl: 30)
      lease.acquire
      Redis::Alfred.delete(key)

      expect { lease.ensure_held! }.to raise_error(described_class::LeaseLostError, /#{inbox_id}/)
    end

    it 'raises LeaseLostError when a newer worker has taken the lease' do
      lease = described_class.new(inbox_id: inbox_id, ttl: 30)
      lease.acquire
      Redis::Alfred.set(key, 'someone-else', ex: 30)

      expect { lease.ensure_held! }.to raise_error(described_class::LeaseLostError)
    end
  end

  describe '.with_lease' do
    it 'yields the lease and releases it afterwards' do
      yielded = nil

      described_class.with_lease(inbox_id: inbox_id, ttl: 30) { |lease| yielded = lease }

      expect(yielded).to be_a(described_class)
      expect(Redis::Alfred.exists?(key)).to be false
    end

    it 'releases the lease when the block raises and preserves the original error' do
      expect { described_class.with_lease(inbox_id: inbox_id, ttl: 30) { raise ArgumentError, 'boom' } }
        .to raise_error(ArgumentError, 'boom')

      expect(Redis::Alfred.exists?(key)).to be false
    end

    it 'raises LeaseNotAcquiredError without yielding when another worker holds the lease' do
      described_class.new(inbox_id: inbox_id, ttl: 30).acquire
      yielded = false

      expect { described_class.with_lease(inbox_id: inbox_id, ttl: 30) { yielded = true } }
        .to raise_error(described_class::LeaseNotAcquiredError)
      expect(yielded).to be false
    end

    it 'does not release a lease held by another worker when acquisition fails' do
      holder = described_class.new(inbox_id: inbox_id, ttl: 30)
      holder.acquire

      expect { described_class.with_lease(inbox_id: inbox_id, ttl: 30) { nil } }
        .to raise_error(described_class::LeaseNotAcquiredError)
      expect(Redis::Alfred.get(key)).to eq holder.token
    end
  end

  describe '.retry_delay' do
    it 'returns a bounded, jittered delay that grows with the attempt' do
      early = described_class.retry_delay(0)
      late = described_class.retry_delay(5)

      expect(early).to be > 0
      expect(late).to be <= described_class::RETRY_MAX_DELAY_SECONDS
      expect(late).to be >= early
    end

    it 'never exceeds the bound even for large attempt counts' do
      100.times do |attempt|
        expect(described_class.retry_delay(attempt)).to be <= described_class::RETRY_MAX_DELAY_SECONDS
      end
    end

    it 'uses the injected random source so the jitter is testable' do
      random = instance_double(Random, rand: 7.0)

      expect(described_class.retry_delay(2, random: random)).to eq 7.0
      expect(random).to have_received(:rand)
    end
  end
end
