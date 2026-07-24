# Historical IMAP identity backfill. Manual and two-phase by design: nothing here is scheduled or
# invoked automatically, and the dry run must be read before an apply is run.
#
#   bundle exec rails 'imap:identity:dry_run[<inbox_id>]'
#   bundle exec rails 'imap:identity:apply[<inbox_id>]'
#
# Omit the inbox id to cover every IMAP-enabled email inbox in the installation.
namespace :imap do
  namespace :identity do
    desc 'Report what an IMAP identity backfill would record. Reads only, writes nothing.'
    task :dry_run, [:inbox_id] => :environment do |_task, args|
      ImapIdentityBackfillTask.each_channel(args[:inbox_id]) do |channel|
        report = Imap::IdentityBackfillService.new(channel: channel).dry_run
        ImapIdentityBackfillTask.print_report(report)
      end
    end

    desc 'Record IMAP identity for exact matches only. Idempotent: re-running records nothing new.'
    task :apply, [:inbox_id] => :environment do |_task, args|
      ImapIdentityBackfillTask.each_channel(args[:inbox_id]) do |channel|
        report = Imap::IdentityBackfillService.new(channel: channel).apply
        ImapIdentityBackfillTask.print_report(report)
        puts "  applied:          #{report[:applied]}"
      end
    end
  end
end

module ImapIdentityBackfillTask
  module_function

  def each_channel(inbox_id)
    channels(inbox_id).each do |channel|
      puts "\n=== inbox #{channel.inbox.id} (#{channel.email}) ==="
      yield channel
    rescue Imap::Lease::LeaseNotAcquiredError
      puts '  SKIPPED: mailbox is busy, another worker holds the lease. Try again shortly.'
    rescue StandardError => e
      puts "  FAILED: #{e.class}: #{e.message}"
    end
  end

  def channels(inbox_id)
    scope = Channel::Email.where(imap_enabled: true)
    return scope.to_a if inbox_id.blank?

    Array(Inbox.find(inbox_id).channel).select { |channel| channel.is_a?(Channel::Email) }
  end

  def print_report(report)
    puts "  mailboxes:        #{report[:mailboxes_scanned].map do |m|
      "#{m[:mailbox]}(uidvalidity=#{m[:uidvalidity]}, #{m[:message_count]} msgs)"
    end.join(', ')}"
    puts "  candidates:       #{report[:candidates]}"
    puts "  exact:            #{report[:exact].length}"
    puts "  ambiguous:        #{report[:ambiguous].length}"
    puts "  missing:          #{report[:missing].length}"
    puts "  stale uidvalidity: #{report[:stale].length}"
    puts "  already recorded: #{report[:already_recorded].length}"
    print_samples(report)
  end

  def print_samples(report)
    report[:ambiguous].first(5).each do |entry|
      puts "    ambiguous #{entry[:message_id]} -> #{entry[:locations].map { |l| "#{l[:mailbox]}:#{l[:uid]}" }.join(', ')}"
    end
    report[:stale].first(5).each do |entry|
      puts "    stale #{entry[:message_id]} stored uidvalidity=#{entry[:stored_uidvalidity]} server=#{entry[:server_uidvalidity]}"
    end
  end
end
