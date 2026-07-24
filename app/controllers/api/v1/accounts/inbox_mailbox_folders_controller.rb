class Api::V1::Accounts::InboxMailboxFoldersController < Api::V1::Accounts::BaseController
  DISCOVERY_ERRORS = [IOError, OpenSSL::SSL::SSLError, Net::IMAP::Error, Timeout::Error, SocketError, Errno::ECONNREFUSED].freeze

  before_action :fetch_inbox
  before_action :validate_imap_email_inbox

  # Reads the server's own folder list so an administrator can see, per role, whether exactly one
  # folder is usable. Discovery results are never stored as authority: they are re-read here and
  # re-validated whenever an override is saved or used.
  def show
    render json: Imap::FolderDiscoveryService.new(channel: @inbox.channel).perform.to_h
  rescue Imap::Lease::LeaseNotAcquiredError
    render json: { error: 'Mailbox is busy, try again shortly' }, status: :conflict
  rescue *DISCOVERY_ERRORS => e
    # The raw server exception is logged, never returned: it can carry mailbox detail.
    Rails.logger.error "[IMAP] Folder discovery failed for inbox #{@inbox.id} : #{e.class}"
    render json: { error: 'Could not read folders from the mail server' }, status: :unprocessable_entity
  end

  private

  def fetch_inbox
    @inbox = Current.account.inboxes.find(params[:inbox_id])
    authorize @inbox, :mailbox_folders?
  end

  def validate_imap_email_inbox
    return if @inbox.inbox_type == 'Email' && @inbox.channel.try(:imap_enabled?)

    render json: { error: 'Not an IMAP enabled email inbox' }, status: :unprocessable_entity
  end
end
