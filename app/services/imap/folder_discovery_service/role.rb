# One role's outcome: exactly what the server said, and what it means for that action.
class Imap::FolderDiscoveryService::Role
  attr_reader :role, :status, :selected, :candidates

  def initialize(role:, status:, selected:, candidates:)
    @role = role
    @status = status
    @selected = selected
    @candidates = candidates
  end

  def available?
    selected.present?
  end

  def ambiguous?
    status == 'ambiguous'
  end

  def to_h
    { role: role, status: status, selected: selected, candidates: candidates, available: available? }
  end
end
