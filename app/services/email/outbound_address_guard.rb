# Keeps an outgoing email honest about our own addresses, on the server, for every client.
#
# Two jobs, both about the same set of addresses:
#
#   assert_from_address! - an agent may send as any address this inbox owns, and as nothing else.
#     A request naming anything else is refused here rather than silently downgraded, so a
#     tampered or stale value can never reach the mailer.
#
#   sanitize - our own addresses must never land in To, Cc or Bcc. A reply that copies one of our
#     aliases is delivered straight back into this inbox as new inbound mail. The composer filters
#     them out as well; this is the guarantee that does not depend on the composer.
class Email::OutboundAddressGuard
  pattr_initialize [:channel!]

  def assert_from_address!(from_email)
    return if from_email.blank?
    return if channel.owned_address(from_email).present?

    raise StandardError, 'Invalid from address for this inbox'
  end

  def sanitize(addresses)
    seen = Set.new

    Array(addresses).reject do |address|
      channel.routes_to_self?(address) || !seen.add?(address.to_s.downcase)
    end
  end
end
