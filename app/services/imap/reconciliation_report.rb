# Imap::ReconciliationReport shapes what one reconciliation pass concluded.
#
# It is a plain hash rather than an object because the job logs it, the specs assert on it, and
# nothing needs behaviour from it. It lives here so the service is about reconciling rather than
# about formatting, and so the three shapes a pass can end in stay visibly parallel.
#
# `conclusive` is the field the job acts on, and it means the same thing in both completed shapes:
# this pass established the truth it set out to establish. A settled pass read every coordinate
# Chatwoot believes in and found all of them; a scanned pass read every folder end to end. A scan
# that could not finish a folder is the one case where it is false.
class Imap::ReconciliationReport
  class << self
    def skipped(inbox_id:, reason:)
      { status: 'skipped', reason: reason, inbox_id: inbox_id }
    end

    # Nothing moved, so nothing was enumerated and no identity coordinates changed. `unchanged`
    # carries the tracked count so the number means the same thing whether or not the scan ran.
    def settled(inbox_id:, probe:, tombstoned:, recovered:)
      base(inbox_id).merge(
        scanned: false, probe: probe_summary(probe), mailboxes_scanned: [], conclusive: true,
        candidates: probe.tracked_count, unchanged: probe.tracked_count,
        recovered: recovered, still_missing: tombstoned, tombstoned: tombstoned
      )
    end

    # Counters start at zero and the pass fills them in as it walks its candidates.
    def for_scan(inbox_id:, scan:, probe:)
      base(inbox_id).merge(
        scanned: true, probe: probe_summary(probe),
        mailboxes_scanned: scan.mailboxes, conclusive: scan.conclusive?
      )
    end

    private

    def base(inbox_id)
      {
        status: 'completed', reason: nil, inbox_id: inbox_id,
        candidates: 0, untracked: 0, unchanged: 0, moved: 0, uidvalidity_resolved: 0,
        recovered: 0, absent_once: 0, marked_missing: 0, still_missing: 0,
        inconclusive: 0, tombstoned: 0
      }
    end

    # A scan driven by the enumeration interval rather than by the probe has no probe to summarise.
    def probe_summary(probe)
      return { skipped: true } if probe.nil?

      {
        tracked: probe.tracked_count, mailboxes: probe.mailboxes_probed.length,
        vanished: probe.vanished.length, generations_changed: probe.generations_changed
      }
    end
  end
end
