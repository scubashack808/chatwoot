# Executes one durable mailbox operation against its frozen PR 04 message identities.
#
# Network work is always inside the PR 03 leased connection wrapper. Each confirmed server result
# is persisted after the command without holding a database row lock across network I/O.
class Imap::MailboxOperationExecutor
  pattr_initialize [:operation!]

  def perform
    operation.start_attempt!
    notify
    ensure_execution_allowed!
    execute_with_connection
    operation.complete!
    notify
    operation
  rescue Imap::Lease::LeaseNotAcquiredError, Imap::Lease::LeaseLostError => e
    operation.mark_pending!(error_code_for(e))
    notify
    raise
  rescue Imap::MailboxOperationRefusedError => e
    operation.mark_failed!(e.code)
    notify
    operation
  rescue StandardError => e
    operation.mark_failed!(error_code_for(e))
    notify
    operation
  end

  private

  def execute_with_connection
    Imap::BaseFetchEmailService.for(channel).with_connection do |client, session|
      capabilities = session.command(&:capabilities)
      targets = resolve_targets(session)
      dialect = Imap::MailboxCommand.dialect_for(client, capabilities: capabilities)
      command = dialect.new(
        session: session,
        client: client,
        targets: targets,
        capabilities: capabilities,
        before_mutation: -> { ensure_execution_allowed! }
      )

      operation.unresolved_items.each { |item| process_item(item, command) }
    end
  end

  def resolve_targets(session)
    listing = session.command { |imap| imap.list('', '*') } || []
    discovery = Imap::FolderDiscoveryService.result_for(folders: listing, config: channel.reload.mailbox_sync)
    targets = %w[archive trash spam].index_with { |role| discovery.for_role(role).selected }
    all_mail = discovery.folders.select do |folder|
      folder[:attributes].include?('all') && folder[:attributes].exclude?(Imap::FolderDiscoveryService::NOSELECT)
    end
    targets['all'] = all_mail.first[:name] if all_mail.one?
    targets
  end

  def process_item(item, command)
    return record_conflict(item, item['preflight_error']) if item['preflight_error'].present?

    message = message_for(item)
    return if message.nil?

    identity = snapshot_identity_for(message, item)
    return if identity.nil?

    result = execute_command(command, identity, item)
    persist_command_result(item, message, identity, result)
  rescue Imap::Lease::LeaseLostError
    raise
  rescue Imap::MailboxOperationRefusedError => e
    record_failure(item, e.code)
  rescue StandardError => e
    record_failure(item, error_code_for(e))
  end

  def message_for(item)
    message = operation.conversation.messages.incoming.find_by(id: item['message_id'])
    record_conflict(item, 'message_not_found') if message.nil?
    message
  end

  def snapshot_identity_for(message, item)
    identity = message.imap_identity
    if identity.nil?
      record_conflict(item, 'identity_missing')
      return
    end
    unless identity_matches_snapshot?(identity, item)
      record_conflict(item, 'identity_version_changed')
      return
    end

    identity
  end

  def execute_command(command, identity, item)
    command.call(
      action: operation.action,
      identity: identity,
      message_id: item['message_source_id'],
      source: item['source']
    )
  end

  def persist_command_result(item, message, identity, result)
    return persist_success(item, message, identity, result) if %i[moved already_in_target].include?(result.status)

    record_conflict(item, 'provider_conflict')
  end

  def identity_matches_snapshot?(identity, item)
    identity.version == item['identity_version'].to_i &&
      identity.locations.include?(item['source'].to_h.stringify_keys)
  end

  def persist_success(item, message, identity, result)
    updated = moved_identity(identity, result, item)
    message.write_imap_identity!(updated)
    operation.record_result!(success_result(item, result, updated))
  end

  def moved_identity(identity, result, item)
    attributes = {
      mailbox: result.target_mailbox,
      uidvalidity: result.target_uidvalidity,
      uid: result.target_uid,
      roles: result.target_roles,
      provider_id: identity.provider_id
    }
    return identity.with_location(**attributes) if result.preserve_source

    identity.moved_to(**attributes.except(:provider_id), source_mailbox: item.dig('source', 'mailbox'))
  end

  def success_result(item, result, updated)
    {
      'message_id' => item['message_id'],
      'status' => 'succeeded',
      'source' => item['source'],
      'target' => {
        'mailbox' => result.target_mailbox,
        'uidvalidity' => result.target_uidvalidity,
        'uid' => result.target_uid,
        'roles' => result.target_roles,
        'identity_version' => updated.version
      }
    }
  end

  def record_conflict(item, code)
    operation.record_result!(
      'message_id' => item['message_id'],
      'status' => 'conflict',
      'source' => item['source'],
      'error_code' => code
    )
    operation.record_error_code!(code)
  end

  def record_failure(item, code)
    operation.record_result!(
      'message_id' => item['message_id'],
      'status' => 'failed',
      'source' => item['source'],
      'error_code' => code
    )
    operation.record_error_code!(code)
  end

  def ensure_execution_allowed!
    raise_refusal('actor_not_authorized') unless actor_authorized?
    raise_refusal('mailbox_actions_disabled') unless operation.account.reload.feature_enabled?('email_mailbox_actions')
    raise_refusal('email_inbox_required') unless channel.is_a?(Channel::Email) && channel.imap_enabled?
    raise_refusal('mailbox_sync_not_active') unless channel.reload.mailbox_sync.provider_mutation_allowed?
  end

  def actor_authorized?
    return false if operation.user_id.blank?

    account_user = AccountUser.find_by(account_id: operation.account_id, user_id: operation.user_id)
    account_user&.administrator? || operation.inbox.inbox_members.exists?(user_id: operation.user_id)
  end

  def raise_refusal(code)
    raise Imap::MailboxOperationRefusedError, code
  end

  def error_code_for(error)
    case error
    when Imap::Lease::LeaseNotAcquiredError then 'mailbox_busy'
    when Imap::Lease::LeaseLostError then 'lease_lost'
    when Net::IMAP::Error then 'imap_error'
    when IOError, OpenSSL::SSL::SSLError then 'connection_error'
    else 'operation_error'
    end
  end

  def channel
    @channel ||= operation.inbox.channel
  end

  def notify
    Imap::MailboxOperationNotifier.call(operation.reload)
  end
end
