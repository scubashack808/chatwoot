module Enterprise::SuperAdmin::AccountsController
  def resource_params
    permitted_params = super
    if action_name == 'update' && params[:account_features_submitted] == '1' && params[:enabled_features].blank?
      permitted_params[:selected_feature_flags] = []
    end
    permitted_params
  end

  def create
    manually_managed = params[:account]&.delete(:manually_managed_features)

    super do |resource|
      if manually_managed.present?
        service = ::Internal::Accounts::InternalAttributesService.new(resource)
        service.manually_managed_features = manually_managed
      end
    end
  end

  def update
    # Handle manually managed features from form submission
    if params[:account] && params[:account][:manually_managed_features].present?
      # Update using the service - it will handle array conversion and validation
      service = ::Internal::Accounts::InternalAttributesService.new(requested_resource)
      service.manually_managed_features = params[:account][:manually_managed_features]

      # Remove the manually_managed_features from params to prevent ActiveModel::UnknownAttributeError
      params[:account].delete(:manually_managed_features)
    end

    super
  end
end
