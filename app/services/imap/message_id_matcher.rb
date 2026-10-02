class Imap::MessageIdMatcher
  HEADER = 'BODY[HEADER.FIELDS (MESSAGE-ID)]'.freeze
  FETCH = ['UID', 'BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)]'].freeze

  def self.call(session:, uids:, message_id:)
    return [] if uids.empty?

    rows = Array(session.command { |imap| imap.uid_fetch(uids, FETCH) })
    rows.filter_map do |row|
      raw = row.attr[HEADER]
      next if raw.blank?
      next unless Mail.read_from_string(raw).message_id == message_id

      row.attr['UID']
    end.uniq
  end
end
