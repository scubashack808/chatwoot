class Imap::SentImportProgress
  class CheckpointConflict < StandardError; end

  VERSION = 1
  # A UID that keeps failing (a body the server never returns, a message that always raises) stops
  # being retried after this many attempts so the retry queue and its search lower bound stay bounded.
  MAX_RETRY_ATTEMPTS = 5

  def initialize(channel:, sent_mailbox:, interval:)
    @channel = channel
    @sent_mailbox = sent_mailbox
    @interval = interval.to_i
    @expected = channel.class.where(id: channel.id).pick(:sent_import_progress).deep_dup
    @state = @expected.deep_dup
    reset_source unless @state['version'] == VERSION && @state['source'] == source
  end

  def select(limit:)
    capture_search if @state['pending_uids'].empty?

    pending = @state['pending_uids']
    retries = @state['retry_uids']
    retry_count = [retries.length, limit / 2].min
    pending_count = [pending.length, limit - retry_count].min
    retry_count = [retries.length, limit - pending_count].min
    pending.first(pending_count) + retries.first(retry_count)
  end

  def acknowledge(uids:, retry_uids:)
    retry_uids = record_attempts(uids, retry_uids)
    pending_failures = @state['pending_uids'] & retry_uids
    remaining_retries = @state['retry_uids'] - (uids - retry_uids)
    retry_dates = []
    retry_dates << @state['retry_since'] if remaining_retries.any?
    retry_dates << @state['active_since'] if pending_failures.any?

    @state['pending_uids'] -= uids
    @state['retry_uids'] = (@state['retry_uids'] - uids) + (uids & retry_uids)
    @state['retry_since'] = retry_dates.compact.min
    checkpoint!
  end

  private

  def record_attempts(uids, retry_uids)
    attempts = @state['retry_attempts'].except(*uids.map(&:to_s))
    exhausted = retry_uids.select do |uid|
      count = @state['retry_attempts'].fetch(uid.to_s, 0) + 1
      attempts[uid.to_s] = count if count < MAX_RETRY_ATTEMPTS
      count >= MAX_RETRY_ATTEMPTS
    end
    Rails.logger.warn "[IMAP::SENT_SYNC] Giving up on #{exhausted.length} Sent UIDs for channel #{@channel.id}" if exhausted.any?
    @state['retry_attempts'] = attempts
    retry_uids - exhausted
  end

  def source
    {
      'provider' => @channel.provider,
      'email' => @channel.email,
      'address' => @channel.imap_address,
      'port' => @channel.imap_port,
      'login' => @channel.imap_login,
      'ssl' => @channel.imap_enable_ssl,
      'mailbox' => @sent_mailbox.mailbox,
      'uidvalidity' => @sent_mailbox.uidvalidity
    }
  end

  def reset_source
    dates = [@state['next_since'], rolling_since]
    dates << @state['active_since'] if @state['pending_uids'].present?
    dates << @state['retry_since'] if @state['retry_uids'].present?
    Rails.logger.info "[IMAP::SENT_SYNC] Resetting import progress for channel #{@channel.id}" if @state.present?
    @state = {
      'version' => VERSION, 'source' => source,
      'pending_uids' => [], 'retry_uids' => [], 'retry_attempts' => {},
      'active_since' => nil, 'next_since' => dates.compact.min, 'retry_since' => nil
    }
  end

  def capture_search
    since = @state.fetch('next_since')
    next_since = rolling_since
    uids = @sent_mailbox.search_since(Date.iso8601(since).strftime('%d-%b-%Y'))
    @state['pending_uids'] = uids.map(&:to_i).uniq.sort - @state['retry_uids']
    @state['active_since'] = since
    @state['next_since'] = next_since
    checkpoint!
  end

  def rolling_since
    (Time.zone.today - @interval).iso8601
  end

  def checkpoint!
    # Runtime checkpoints use an atomic compare-and-swap, without configuration validation or audit callbacks.
    scope = @channel.class.where(id: @channel.id, sent_import_progress: @expected)
    updated = scope.update_all(sent_import_progress: @state) # rubocop:disable Rails/SkipsModelValidations
    raise CheckpointConflict, "Sent import progress changed for channel #{@channel.id}" unless updated == 1

    @expected = @state.deep_dup
  end
end
