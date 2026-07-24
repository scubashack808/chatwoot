# Imap::Lease is a mail-specific, owner-token lease that serializes all per-inbox IMAP work.
#
# It exists alongside Redis::LockManager rather than replacing it. The generic lock manager
# releases with an unconditional DELETE, so a worker that overruns the TTL can delete a newer
# worker's lock (see the comment on MutexApplicationJob#with_lock). Mailbox work mutates a real
# mail server, so it needs an owner-checked release, an owner-checked renewal, and a way to stop
# BEFORE the next IMAP command once the lease is gone.
#
# These are mailbox-local bounds, not a new global locking framework.
#
# Example:
#
#   Imap::Lease.with_lease(inbox_id: inbox.id) do |lease|
#     lease.ensure_held!          # renew before each command; raises if the lease was lost
#     imap.uid_move(uid, target)
#   end
#
class Imap::Lease
  # Raised when the lease is no longer owned by this worker. Callers must stop before issuing
  # any further provider command.
  class LeaseLostError < StandardError; end

  # Raised when another worker already holds the lease. This is contention, not a failure:
  # callers defer politely and retry later. They never open a second connection as a fallback.
  class LeaseNotAcquiredError < StandardError; end

  DEFAULT_TTL_SECONDS = 120
  RETRY_BASE_DELAY_SECONDS = 5
  RETRY_MAX_DELAY_SECONDS = 60
  MAX_BACKOFF_EXPONENT = 4

  attr_reader :inbox_id, :key, :token, :ttl

  def initialize(inbox_id:, ttl: DEFAULT_TTL_SECONDS, token: nil)
    @inbox_id = inbox_id
    @key = format(::Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: inbox_id)
    @ttl = ttl.to_i
    @token = token.presence || SecureRandom.uuid
  end

  # Acquires the lease only when nobody else holds it.
  def acquire
    ::Redis::Alfred.set(key, token, nx: true, ex: ttl) ? true : false
  end

  def held?
    ::Redis::Alfred.get(key) == token
  end

  # Extends the lease only while the stored token still matches ours. A lease that expired and
  # was taken by a newer worker is never resurrected or stolen back.
  def renew
    outcome = ::Redis::Alfred.with do |conn|
      conn.watch(key) do
        next conn.unwatch && nil unless conn.get(key) == token

        conn.multi { |transaction| transaction.expire(key, ttl) }
      end
    end

    truthy_transaction_result?(outcome)
  end

  # Renews and raises if the lease is gone, so a caller can call this immediately before each
  # IMAP command and stop before touching the provider.
  def ensure_held!
    return true if renew

    raise LeaseLostError, "IMAP lease lost for inbox #{inbox_id}"
  end

  # Releases only our own lease. Never deletes a newer worker's lease.
  def release
    truthy_transaction_result?(::Redis::Alfred.delete_if_equals(key, token))
  end

  class << self
    def with_lease(inbox_id:, ttl: DEFAULT_TTL_SECONDS, token: nil)
      lease = new(inbox_id: inbox_id, ttl: ttl, token: token)

      raise LeaseNotAcquiredError, "IMAP lease busy for inbox #{inbox_id}" unless lease.acquire

      begin
        yield lease
      ensure
        lease.release
      end
    end

    # Bounded exponential backoff with jitter, so contending workers spread out instead of
    # synchronising on the next cycle. The random source is injectable for tests.
    def retry_delay(attempt, random: Random)
      exponent = [attempt.to_i, MAX_BACKOFF_EXPONENT].min
      capped = [RETRY_BASE_DELAY_SECONDS * (2**exponent), RETRY_MAX_DELAY_SECONDS].min

      random.rand((capped / 2.0)..capped.to_f)
    end
  end

  private

  # Redis returns the transaction's replies on success and nil when WATCH aborted it.
  def truthy_transaction_result?(outcome)
    return false unless outcome.is_a?(Array)

    [true, 1].include?(outcome.first)
  end
end
