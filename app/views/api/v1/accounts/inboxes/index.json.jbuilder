json.payload do
  json.array! @inboxes do |inbox|
    json.partial! 'api/v1/models/inbox', formats: [:json], resource: inbox
    json.current_user_is_member @current_user_inbox_ids.key?(inbox.id)
  end
end
