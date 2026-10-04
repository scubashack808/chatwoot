require 'rails_helper'

RSpec.describe 'Super Admin account feature selection', if: ChatwootApp.enterprise?, type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account) }

  before do
    account.update!(selected_feature_flags: [:feature_help_center])
    sign_in(super_admin, scope: :super_admin)
  end

  it 'persists clearing the last feature from the rendered all-unchecked form' do
    get "/super_admin/accounts/#{account.id}/edit"

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    checkbox = document.at_css('input[name="enabled_features[feature_help_center]"]')
    expect([checkbox['checked'].present?, checkbox['disabled']]).to eq([true, nil])
    feature_fields = checkbox.ancestors('.feature-container').first
    hidden_inputs = feature_fields.css('input[type="hidden"]:not([disabled])')
    submission = hidden_inputs.to_h { |input| [input['name'], input['value']] }
    expect(submission).to eq('account_features_submitted' => '1')

    patch "/super_admin/accounts/#{account.id}", params: submission.merge(account: { name: 'All unchecked account' })

    expect(response).to have_http_status(:redirect)
    expect(account.reload.name).to eq('All unchecked account')
    expect(account.feature_enabled?('help_center')).to be(false)
    expect(account).to have_attributes(feature_flags: 0, feature_flags_ext_1: 0)
  end

  it 'replaces help_center with campaigns with a submission marker' do
    patch "/super_admin/accounts/#{account.id}", params: {
      account: { name: 'Marked replacement account' }, account_features_submitted: '1', enabled_features: { feature_campaigns: 'true' }
    }

    expect(response).to have_http_status(:redirect)
    expect(account.reload.feature_enabled?('help_center')).to be(false)
    expect(account.feature_enabled?('campaigns')).to be(true)
  end

  it 'preserves features when an unrelated update omits the marker and selection' do
    patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'Unrelated update' } }

    expect(response).to have_http_status(:redirect)
    expect(account.reload.name).to eq('Unrelated update')
    expect(account.feature_enabled?('help_center')).to be(true)
  end

  it 'retains account creation defaults when the marker is submitted without selections' do
    InstallationConfig.find_or_initialize_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS').update!(value: [{ 'name' => 'help_center', 'enabled' => true }])
    GlobalConfig.clear_cache

    expect do
      post '/super_admin/accounts', params: { account: { name: 'Created account' }, account_features_submitted: '1' }
    end.to change(Account, :count).by(1)

    expect(response).to have_http_status(:redirect)
    expect(Account.find_by!(name: 'Created account').feature_enabled?('help_center')).to be(true)
  end

  it 'replaces help_center with campaigns without a submission marker' do
    patch "/super_admin/accounts/#{account.id}",
          params: { account: { name: 'Replacement account' }, enabled_features: { feature_campaigns: 'true' } }

    expect(response).to have_http_status(:redirect)
    expect(account.reload.feature_enabled?('help_center')).to be(false)
    expect(account.feature_enabled?('campaigns')).to be(true)
  end
end
