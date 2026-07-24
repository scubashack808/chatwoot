# Imap::Session owns the lifetime of a single IMAP connection so that every exit path closes it.
#
# Imap::BaseFetchEmailService#perform used to call terminate_imap_connection only after
# fetch_emails returned, so an exception during connect, authenticate, select, search, or fetch
# bypassed cleanup entirely. It also called logout without disconnect, which sends the LOGOUT
# command but leaves the socket open. Both shapes leak connections against a server with a
# per-account connection limit.
#
# The invariant this class enforces:
#
#   - the raw connection is captured the moment it exists, before authentication runs, so a
#     failure during authenticate or select still has something to close;
#   - close runs in an ensure, logs out when healthy, and always falls through to disconnect;
#   - a cleanup failure is logged and swallowed so it can never mask the original error;
#   - every command renews the lease first and stops before touching the provider if it was lost.
#
# Bounds are mailbox-local constants. Timeout.timeout is used rather than Net::IMAP's own
# open_timeout because it also covers a hang during authenticate or select, and because it is the
# idiom already used in this code path by Inboxes::FetchImapEmailsJob.
class Imap::Session
  CONNECT_TIMEOUT_SECONDS = 15
  COMMAND_TIMEOUT_SECONDS = 45

  attr_reader :client, :lease

  def initialize(lease: nil, connect_timeout: CONNECT_TIMEOUT_SECONDS, command_timeout: COMMAND_TIMEOUT_SECONDS)
    @lease = lease
    @connect_timeout = connect_timeout
    @command_timeout = command_timeout
    @client = nil
  end

  def self.run(lease: nil, connect_timeout: CONNECT_TIMEOUT_SECONDS, command_timeout: COMMAND_TIMEOUT_SECONDS)
    session = new(lease: lease, connect_timeout: connect_timeout, command_timeout: command_timeout)

    begin
      yield session
    ensure
      session.close
    end
  end

  # Establishes the connection and captures it immediately, so that a later failure during
  # authentication or mailbox selection still has a socket to close.
  def connect
    lease&.ensure_held!

    Timeout.timeout(@connect_timeout) do
      @client = yield
    end
  end

  # Runs one IMAP command under the per-command bound, after confirming the lease is still ours.
  def command
    lease&.ensure_held!

    Timeout.timeout(@command_timeout) { yield client }
  end

  def connected?
    !client.nil?
  end

  # Never raises. A cleanup failure must not replace the caller's original error.
  def close
    current = @client
    @client = nil
    return false if current.nil?
    return true if already_disconnected?(current)

    attempt_logout(current)
    attempt_disconnect(current)
    true
  end

  private

  def already_disconnected?(current)
    current.disconnected?
  rescue StandardError
    false
  end

  def attempt_logout(current)
    Timeout.timeout(@command_timeout) { current.logout }
  rescue StandardError => e
    Rails.logger.info "[IMAP::SESSION] Logout failed, falling through to disconnect: #{e.class}."
  end

  def attempt_disconnect(current)
    current.disconnect
  rescue StandardError => e
    Rails.logger.info "[IMAP::SESSION] Disconnect failed: #{e.class}."
  end
end
