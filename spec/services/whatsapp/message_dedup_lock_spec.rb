require 'rails_helper'

describe Whatsapp::MessageDedupLock do
  let(:source_id) { "wamid.test_#{SecureRandom.hex(8)}" }
  let(:lock) { described_class.new(source_id) }
  let(:redis_key) { format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: source_id) }

  after { Redis::Alfred.delete(redis_key) }

  describe '#release!' do
    it 'releases its own claim and allows replay' do
      expect(lock.acquire!).to be(true)
      expect(Redis::Alfred.ttl(redis_key)).to be_between(86_000, 86_400)
      lock.release!
      expect(Redis::Alfred.exists?(redis_key)).to be(false)
      expect(described_class.new(source_id).acquire!).to be(true)
      replacement = Redis::Alfred.get(redis_key)
      lock.release!
      expect(Redis::Alfred.get(redis_key)).to eq(replacement)
    end

    it 'does not release another owner after a denied acquisition' do
      lock.acquire!
      token = Redis::Alfred.get(redis_key)
      contender = described_class.new(source_id)
      expect(contender.acquire!).to be(false)
      contender.release!
      expect(Redis::Alfred.get(redis_key)).to eq(token)
    end

    it 'does not delete a replacement claim' do
      lock.acquire!
      original_token = Redis::Alfred.get(redis_key)
      Redis::Alfred.delete(redis_key)
      replacement = described_class.new(source_id)
      replacement.acquire!
      replacement_token = Redis::Alfred.get(redis_key)
      expect(replacement_token).not_to eq(original_token)
      lock.release!
      expect(Redis::Alfred.get(redis_key)).to eq(replacement_token)
    end
  end

  describe '#acquire!' do
    it 'returns truthy on first acquire' do
      expect(lock.acquire!).to be_truthy
    end

    it 'returns falsy on second acquire for the same source_id' do
      lock.acquire!
      expect(described_class.new(source_id).acquire!).to be_falsy
    end

    it 'allows different source_ids to acquire independently' do
      lock.acquire!
      other = described_class.new("wamid.other_#{SecureRandom.hex(8)}")
      expect(other.acquire!).to be_truthy
    end

    it 'lets exactly one thread win when two race for the same source_id' do
      results = Concurrent::Array.new
      barrier = Concurrent::CyclicBarrier.new(2)

      threads = Array.new(2) do
        Thread.new do
          barrier.wait
          results << described_class.new(source_id).acquire!
        end
      end

      threads.each(&:join)

      wins = results.count { |r| r }
      expect(wins).to eq(1), "Expected exactly 1 winner but got #{wins}. Results: #{results.inspect}"
    end
  end
end
