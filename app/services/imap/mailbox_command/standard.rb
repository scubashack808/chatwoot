# Standard IMAP mailbox actions use UID MOVE to one exact, freshly resolved target mailbox.
class Imap::MailboxCommand::Standard
  Result = Imap::MailboxCommand::Result
  RESTORE_TARGET = Imap::MailboxCommand::RESTORE_TARGET

  def initialize(session:, client:, targets:, capabilities: nil, before_mutation: nil)
    @session = session
    @client = client
    @targets = targets
    @capabilities = capabilities || client.capabilities
    @before_mutation = before_mutation || -> {}
  end

  def call(action:, identity:, message_id: nil, source: nil)
    action = action.to_sym
    target = target_for(action)
    return conflict("#{action} target is not configured for this inbox") if target.blank?

    source = (source || identity.primary).to_h.stringify_keys
    verification = verify_source(source)
    return verification if verification.is_a?(Result)
    return recover_missing_source(action, identity, target, message_id) if verification == :missing
    return already_in_target(action, source) if source['mailbox'] == target
    return conflict('server does not advertise UID MOVE') unless move_supported?

    perform(action: action, identity: identity, source: source, target: target, message_id: message_id)
  end

  private

  attr_reader :session, :client, :targets, :capabilities, :before_mutation

  def perform(action:, identity:, source:, target:, message_id:)
    move(action: action, identity: identity, source: source, target: target, message_id: message_id)
  end

  def target_for(action)
    return RESTORE_TARGET if action == :restore

    targets[action.to_s]
  end

  def target_roles(action)
    action == :restore ? ['inbox'] : [action.to_s]
  end

  # Selects the exact source mailbox, proves its UID generation, and then checks that the UID
  # still exists. A changed UIDVALIDITY is never repaired inside a mutation path.
  def verify_source(source)
    session.command { |imap| imap.select(source['mailbox']) }
    current = Array(client.responses('UIDVALIDITY')).last

    if current.to_i != source['uidvalidity'].to_i
      return conflict("mailbox uidvalidity changed from #{source['uidvalidity']} to #{current}, stored uid is stale")
    end

    present = Array(session.command { |imap| imap.uid_search(['UID', source['uid']]) }).include?(source['uid'])
    present ? :present : :missing
  end

  def recover_missing_source(action, identity, target, message_id)
    recovered = confirm_target(
      action: action,
      target: target,
      identity: identity,
      message_id: message_id,
      outcome: { status: :already_in_target }
    )

    return recovered unless recovered.status == :conflict

    conflict('uid is no longer present and the requested target could not be confirmed uniquely')
  end

  def already_in_target(action, source)
    moved(
      source['mailbox'],
      source['uidvalidity'],
      source['uid'],
      status: :already_in_target,
      roles: target_roles(action)
    )
  end

  def move(action:, identity:, source:, target:, message_id:)
    client.clear_responses('COPYUID')
    session.command do |imap|
      before_mutation.call
      imap.uid_move(source['uid'], target)
    end

    copyuid = Array(client.responses('COPYUID')).last
    if copyuid.present?
      return moved(
        target,
        copyuid.uidvalidity,
        copyuid.assigned_uids.to_a.fetch(0),
        roles: target_roles(action)
      )
    end

    confirm_target(action: action, target: target, identity: identity, message_id: message_id, outcome: { status: :moved })
  end

  def confirm_target(action:, target:, identity:, message_id:, outcome:)
    query = stable_search(identity, message_id)
    return conflict('target cannot be confirmed because the message has no stable identifier') if query.nil?

    session.command { |imap| imap.select(target) }
    uidvalidity = Array(client.responses('UIDVALIDITY')).last
    hits = Array(session.command { |imap| imap.uid_search(query) })

    return conflict("target could not be confirmed uniquely, #{hits.length} candidates") unless hits.one?

    moved(target, uidvalidity, hits.first, **outcome, roles: target_roles(action))
  end

  def stable_search(_identity, message_id)
    return if message_id.blank?

    ['HEADER', 'MESSAGE-ID', message_id]
  end

  def move_supported?
    capabilities.include?('MOVE')
  end

  def moved(mailbox, uidvalidity, uid, **outcome)
    Result.new(
      status: outcome.fetch(:status, :moved),
      target_mailbox: mailbox,
      target_uidvalidity: uidvalidity,
      target_uid: uid,
      target_roles: outcome[:roles],
      detail: outcome[:detail],
      preserve_source: outcome[:preserve_source]
    )
  end

  def conflict(detail)
    Result.new(status: :conflict, detail: detail)
  end
end
