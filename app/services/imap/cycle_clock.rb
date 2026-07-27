# Imap::CycleClock records when a per-inbox reconciliation event last happened, so the pass can
# reason about elapsed time without every caller hand-rolling the same Redis key formatting and
# blank handling.
#
# Two things use it for different reasons. The service asks how long since the last full
# enumeration, because the cheap probe cannot see a new copy appear and enumeration therefore has
# to happen on an interval regardless. The job asks how long since the last successful cycle,
# because an inbox that has silently stopped reconciling looks exactly like an inbox where nothing
# has moved.
#
# A clock that has never been set reports nil rather than zero. That difference matters: "never
# happened" is what makes the first cycle enumerate, and it is also what stops a newly managed
# inbox from reporting a stall it never had.
class Imap::CycleClock
  pattr_initialize [:inbox!, :key_template!]

  def record
    Redis::Alfred.set(key, Time.current.to_i)
  end

  # Seconds since the last record, or nil if it has never been recorded.
  def elapsed
    last = Redis::Alfred.get(key)
    return nil if last.blank?

    Time.current.to_i - last.to_i
  end

  # Never recorded counts as due, so the first cycle always does the expensive thing.
  def due?(interval)
    seconds = elapsed
    seconds.nil? || seconds >= interval.to_i
  end

  private

  def key
    format(key_template, inbox_id: inbox.id)
  end
end
