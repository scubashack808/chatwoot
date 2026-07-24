# The resolved discovery outcome for one inbox.
class Imap::FolderDiscoveryService::Result
  # A compact class definition does not inherit the outer class's lexical scope, so the shared
  # constants are bound locally here.
  ROLE_ATTRIBUTES = Imap::FolderDiscoveryService::ROLE_ATTRIBUTES
  NOSELECT = Imap::FolderDiscoveryService::NOSELECT
  Role = Imap::FolderDiscoveryService::Role

  attr_reader :folders

  def initialize(folders:, config:)
    @folders = folders
    @config = config
    @roles = ROLE_ATTRIBUTES.keys.index_with { |role| resolve(role) }
  end

  def for_role(role)
    @roles[role.to_s]
  end

  def to_h
    { folders: folders, roles: @roles.transform_values(&:to_h) }
  end

  # Whether an exact folder name exists on the server right now and can actually be selected.
  # This is what an administrator override is checked against, both when saved and when used.
  def selectable_folder?(name)
    folder = folders.find { |candidate| candidate[:name] == name }

    folder.present? && folder[:attributes].exclude?(NOSELECT)
  end

  private

  def resolve(role)
    candidates = candidates_for(role)
    override = @config.override_for(role)

    return resolve_override(role, override, candidates) if override.present?

    Role.new(role: role, status: status_for(candidates), selected: (candidates.first if candidates.one?), candidates: candidates)
  end

  # An override is re-validated against this fresh LIST every time it is used. A folder that has
  # been renamed or removed on the server leaves the role unavailable rather than silently
  # falling back to discovery.
  def resolve_override(role, override, candidates)
    return Role.new(role: role, status: 'overridden', selected: override, candidates: candidates) if selectable_folder?(override)

    Role.new(role: role, status: 'invalid_override', selected: nil, candidates: candidates)
  end

  def candidates_for(role)
    attribute = ROLE_ATTRIBUTES.fetch(role)

    folders.filter_map do |folder|
      next unless folder[:attributes].include?(attribute)
      next if folder[:attributes].include?(NOSELECT)

      folder[:name]
    end
  end

  def status_for(candidates)
    case candidates.length
    when 0 then 'unavailable'
    when 1 then 'discovered'
    else 'ambiguous'
    end
  end
end
