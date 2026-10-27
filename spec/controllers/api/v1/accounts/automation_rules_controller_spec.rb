require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::AutomationRulesController', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let!(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, inbox_id: inbox.id, contact_id: contact.id) }

  describe 'GET /api/v1/accounts/{account.id}/automation_rules' do
    context 'when it is an authenticated user' do
      it 'returns all records' do
        automation_rule = create(:automation_rule, account: account, name: 'Test Automation Rule')

        get "/api/v1/accounts/#{account.id}/automation_rules",
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:payload].first[:id]).to eq(automation_rule.id)
      end
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/automation_rules"

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/automation_rules' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/automation_rules"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:params) do
        {
          'name': 'Notify Conversation Created and mark priority query',
          'description': 'Notify all administrator about conversation created and mark priority query',
          'event_name': 'conversation_created',
          'conditions': [
            {
              'attribute_key': 'browser_language',
              'filter_operator': 'equal_to',
              'values': ['en'],
              'query_operator': 'AND'
            },
            {
              'attribute_key': 'country_code',
              'filter_operator': 'equal_to',
              'values': %w[USA UK],
              'query_operator': nil
            }
          ],
          'actions': [
            {
              'action_name': :send_message,
              'action_params': ['Welcome to the chatwoot platform.']
            },
            {
              'action_name': :assign_team,
              'action_params': [1]
            },
            {
              'action_name': :remove_assigned_agent
            },
            {
              'action_name': :remove_assigned_team
            },
            {
              'action_name': :add_label,
              'action_params': %w[support priority_customer]
            }
          ]
        }
      end

      it 'processes invalid query operator' do
        expect(account.automation_rules.count).to eq(0)
        params[:conditions] << {
          'attribute_key': 'browser_language',
          'filter_operator': 'equal_to',
          'values': ['en'],
          'query_operator': 'invalid'
        }

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(account.automation_rules.count).to eq(0)
      end

      it 'throws an error for unknown attributes in condtions' do
        expect(account.automation_rules.count).to eq(0)
        params[:conditions] << {
          'attribute_key': 'unknown_attribute',
          'filter_operator': 'equal_to',
          'values': ['en'],
          'query_operator': 'AND'
        }

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(account.automation_rules.count).to eq(0)
      end

      it 'Saves for automation_rules for account with country_code and browser_language conditions' do
        expect(account.automation_rules.count).to eq(0)

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.count).to eq(1)
      end

      it 'Saves for automation_rules for account with status conditions' do
        params[:conditions] = [
          {
            attribute_key: 'status',
            filter_operator: 'equal_to',
            values: ['resolved'],
            query_operator: nil
          }
        ]
        expect(account.automation_rules.count).to eq(0)

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.count).to eq(1)
      end

      it 'Saves file in the automation actions to send an attachments' do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/assets/avatar.png').open,
          filename: 'avatar.png',
          content_type: 'image/png'
        )

        expect(account.automation_rules.count).to eq(0)

        params[:actions] = [
          {
            'action_name': :send_message,
            'action_params': ['Welcome to the chatwoot platform.']
          },
          {
            'action_name': :send_attachment,
            'action_params': [blob.signed_id]
          }
        ]

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        automation_rule = account.automation_rules.first
        expect(automation_rule.files.presence).to be_truthy
        expect(automation_rule.files.count).to eq(1)
      end

      it 'Saves files in the automation actions to send multiple attachments' do
        blob_1 = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/assets/avatar.png').open,
          filename: 'avatar.png',
          content_type: 'image/png'
        )
        blob_2 = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/assets/sample.png').open,
          filename: 'sample.png',
          content_type: 'image/png'
        )

        params[:actions] = [
          {
            'action_name': :send_attachment,
            'action_params': [blob_1.signed_id]
          },
          {
            'action_name': :send_attachment,
            'action_params': [blob_2.signed_id]
          }
        ]

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        automation_rule = account.automation_rules.first
        expect(automation_rule.files.count).to eq(2)
      end

      it 'returns error for invalid attachment blob_id' do
        params[:actions] = [
          {
            'action_name': :send_attachment,
            'action_params': ['invalid_blob_id']
          }
        ]

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to eq(I18n.t('errors.attachments.invalid'))
      end

      it 'stores the original blob_id in action_params after create' do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/assets/avatar.png').open,
          filename: 'avatar.png',
          content_type: 'image/png'
        )

        params[:actions] = [
          {
            'action_name': :send_attachment,
            'action_params': [blob.signed_id]
          }
        ]

        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: params

        automation_rule = account.automation_rules.first
        attachment_action = automation_rule.actions.find { |a| a['action_name'] == 'send_attachment' }
        expect(attachment_action['action_params'].first).to be_a(Integer)
        expect(attachment_action['action_params'].first).to eq(automation_rule.files.first.blob_id)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/automation_rules/{automation_rule.id}' do
    let!(:automation_rule) { create(:automation_rule, account: account, name: 'Test Automation Rule') }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'returns for automation_rule for account' do
        expect(account.automation_rules.count).to eq(1)

        get "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:payload]).to be_present
        expect(body[:payload][:id]).to eq(automation_rule.id)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/automation_rules/{automation_rule.id}/clone' do
    let!(:automation_rule) { create(:automation_rule, account: account, name: 'Test Automation Rule') }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}/clone"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'returns for cloned automation_rule for account' do
        expect(account.automation_rules.count).to eq(1)

        post "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}/clone",
             headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:payload]).to be_present
        expect(body[:payload][:id]).not_to eq(automation_rule.id)
        expect(account.automation_rules.count).to eq(2)
      end
    end
  end

  describe 'cloning attachment automations' do
    let(:headers) { administrator.create_new_auth_token }
    let(:blob) do
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new('automation attachment'), filename: 'workflow.txt', content_type: 'text/plain')
    end
    let(:rule_params) do
      {
        name: 'Attachment rule', event_name: 'conversation_created',
        conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['open'], query_operator: nil }],
        actions: [{ action_name: 'send_attachment', action_params: [blob.signed_id] }]
      }
    end
    let(:source) { account.automation_rules.order(:id).first }
    let(:copy) { account.automation_rules.order(:id).last }

    before do
      post "/api/v1/accounts/#{account.id}/automation_rules", headers: headers, params: rule_params
    end

    it 'creates separate attachment rows with the same blobs and complete file metadata' do
      expect do
        post "/api/v1/accounts/#{account.id}/automation_rules/#{source.id}/clone", headers: headers
      end.not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:success)
      expect(copy.id).not_to eq(source.id)
      expect(copy).to have_attributes(account_id: source.account_id, actions: source.actions, conditions: source.conditions)
      expect(copy.files.pluck(:id) & source.files.pluck(:id)).to be_empty
      file = response.parsed_body['payload']['files'].sole
      expect(file).to include('id' => copy.files.sole.id, 'automation_rule_id' => copy.id, 'account_id' => account.id,
                              'blob_id' => blob.id, 'filename' => 'workflow.txt', 'file_type' => 'text/plain')
      expect(file['file_url']).to be_present
    end

    it 'retains all attachments when a rule has multiple files' do
      second_blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('second attachment'), filename: 'second.txt', content_type: 'text/plain')
      actions = [{ action_name: 'send_attachment', action_params: [blob.id] },
                 { action_name: 'send_attachment', action_params: [second_blob.signed_id] }]
      patch "/api/v1/accounts/#{account.id}/automation_rules/#{source.id}", headers: headers, as: :json, params: { actions: actions }
      expect(response).to have_http_status(:success)

      post "/api/v1/accounts/#{account.id}/automation_rules/#{source.id}/clone", headers: headers

      expect(response).to have_http_status(:success)
      expect(copy.files.pluck(:blob_id)).to contain_exactly(blob.id, second_blob.id)
      expect(copy.actions).to eq(source.reload.actions)
    end

    it 'allows saving the cloned actions without re-uploading the attachment' do
      post "/api/v1/accounts/#{account.id}/automation_rules/#{source.id}/clone", headers: headers
      expect(response).to have_http_status(:success)

      patch "/api/v1/accounts/#{account.id}/automation_rules/#{copy.id}", headers: headers, params: { actions: copy.actions }, as: :json

      expect(response).to have_http_status(:success)
      expect(copy.reload.actions).to eq(source.actions)
      expect(copy.files.sole.blob_id).to eq(blob.id)
    end

    it 'sends exactly one outgoing attachment message from each rule' do
      post "/api/v1/accounts/#{account.id}/automation_rules/#{source.id}/clone", headers: headers
      expect(response).to have_http_status(:success)
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)

      [source, copy].each do |rule|
        expect do
          AutomationRules::ActionService.new(rule, account, conversation).perform
        end.to change { conversation.messages.outgoing.count }.by(1)
        message = conversation.messages.outgoing.last
        expect(message.private).to be(false)
        expect(message.attachments.sole.file.blob_id).to eq(blob.id)
        expect(message.attachments.sole.file.download).to eq('automation attachment')
      end
    end

    %w[source copy].each do |deleted_rule|
      it "keeps the file after deleting the #{deleted_rule} and purges it after deleting the survivor" do
        post "/api/v1/accounts/#{account.id}/automation_rules/#{source.id}/clone", headers: headers
        expect(response).to have_http_status(:success)
        removed, survivor = deleted_rule == 'source' ? [source, copy] : [copy, source]
        blob_key = blob.key
        storage = blob.service

        perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
          delete "/api/v1/accounts/#{account.id}/automation_rules/#{removed.id}", headers: headers
          expect(response).to have_http_status(:success)
        end

        expect(survivor.reload.files.sole.download).to eq('automation attachment')
        expect(storage.exist?(blob_key)).to be(true)

        perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
          delete "/api/v1/accounts/#{account.id}/automation_rules/#{survivor.id}", headers: headers
          expect(response).to have_http_status(:success)
        end

        expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
        expect(storage.exist?(blob_key)).to be(false)
      end
    end

    it 'does not accept a numeric blob ID from another account on the clone' do
      other_rule = create(:automation_rule)
      other_rule.files.attach(io: StringIO.new('other account'), filename: 'other.txt', content_type: 'text/plain')
      post "/api/v1/accounts/#{account.id}/automation_rules/#{source.id}/clone", headers: headers
      expect(response).to have_http_status(:success)

      actions = [{ action_name: 'send_attachment', action_params: [other_rule.files.sole.blob_id] }]
      patch "/api/v1/accounts/#{account.id}/automation_rules/#{copy.id}", headers: headers, params: { actions: actions }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(copy.reload.actions).to eq(source.actions)
      expect(copy.files.pluck(:blob_id)).to eq([blob.id])
    end

    it 'does not allow an administrator from another account to clone the rule' do
      other_administrator = create(:user, account: create(:account), role: :administrator)
      expect do
        post "/api/v1/accounts/#{account.id}/automation_rules/#{source.id}/clone", headers: other_administrator.create_new_auth_token
      end.not_to change(AutomationRule, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    context 'with a private note and no files' do
      let(:rule_params) { super().merge(actions: [{ action_name: 'add_private_note', action_params: ['Internal note'] }]) }

      it 'preserves the action and executes the cloned private note' do
        post "/api/v1/accounts/#{account.id}/automation_rules/#{source.id}/clone", headers: headers
        expect(response).to have_http_status(:success)
        expect(copy.actions).to eq(source.actions)
        expect(copy.files).not_to be_attached
        conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)

        expect do
          AutomationRules::ActionService.new(copy, account, conversation).perform
        end.to change { conversation.messages.outgoing.count }.by(1)
        expect(conversation.messages.outgoing.last).to have_attributes(content: 'Internal note', private: true)
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/automation_rules/{automation_rule.id}' do
    let!(:automation_rule) { create(:automation_rule, account: account, name: 'Test Automation Rule') }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:update_params) do
        {
          'description': 'Update description',
          'name': 'Update name',
          'conditions': [
            {
              'attribute_key': 'browser_language',
              'filter_operator': 'equal_to',
              'values': ['en'],
              'query_operator': 'AND'
            }
          ],
          'actions': [
            {
              'action_name': :add_label,
              'action_params': %w[support priority_customer]
            }
          ]
        }
      end

      it 'returns for cloned automation_rule for account' do
        expect(account.automation_rules.count).to eq(1)
        expect(account.automation_rules.first.actions.size).to eq(4)

        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
              headers: administrator.create_new_auth_token,
              params: update_params

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:payload][:name]).to eq('Update name')
        expect(body[:payload][:description]).to eq('Update description')
        expect(body[:payload][:conditions].size).to eq(1)
        expect(body[:payload][:actions].size).to eq(1)
      end

      it 'returns for updated active flag for automation_rule' do
        expect(automation_rule.active).to be(true)
        params = { active: false }

        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
              headers: administrator.create_new_auth_token,
              params: params

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:payload][:active]).to be(false)
        expect(automation_rule.reload.active).to be(false)
      end

      it 'allows update with existing blob_id' do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/assets/avatar.png').open,
          filename: 'avatar.png',
          content_type: 'image/png'
        )

        automation_rule.update!(actions: [{ 'action_name' => 'send_attachment', 'action_params' => [blob.id] }])
        automation_rule.files.attach(blob)

        update_params[:actions] = [
          {
            'action_name': :send_attachment,
            'action_params': [blob.id]
          }
        ]

        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
              headers: administrator.create_new_auth_token,
              params: update_params

        expect(response).to have_http_status(:success)
      end

      it 'returns error for invalid blob_id on update' do
        update_params[:actions] = [
          {
            'action_name': :send_attachment,
            'action_params': [999_999]
          }
        ]

        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
              headers: administrator.create_new_auth_token,
              params: update_params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to eq(I18n.t('errors.attachments.invalid'))
      end

      it 'allows adding new attachment on update with signed blob_id' do
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rails.root.join('spec/assets/avatar.png').open,
          filename: 'avatar.png',
          content_type: 'image/png'
        )

        update_params[:actions] = [
          {
            'action_name': :send_attachment,
            'action_params': [blob.signed_id]
          }
        ]

        patch "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
              headers: administrator.create_new_auth_token,
              params: update_params

        expect(response).to have_http_status(:success)
        expect(automation_rule.reload.files.count).to eq(1)
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/automation_rules/{automation_rule.id}' do
    let!(:automation_rule) { create(:automation_rule, account: account, name: 'Test Automation Rule') }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'delete the automation_rule for account' do
        expect(account.automation_rules.count).to eq(1)

        delete "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}",
               headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.count).to eq(0)
      end
    end
  end

  describe 'execution_delay handling' do
    let(:delayed_rule_params) do
      {
        name: 'Delayed rule',
        event_name: 'conversation_updated',
        execution_delay: 240,
        conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['pending'], query_operator: nil }],
        actions: [{ action_name: 'add_label', action_params: ['stale'] }]
      }
    end

    context 'when the delayed_automations feature is enabled' do
      before { account.enable_features!('delayed_automations') }

      it 'persists and serializes execution_delay' do
        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: delayed_rule_params

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:execution_delay]).to eq(240)
        expect(account.automation_rules.last.execution_delay).to eq(240)
      end

      it 'copies execution_delay on clone' do
        automation_rule = create(:automation_rule, account: account, execution_delay: 240)

        post "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}/clone",
             headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.last.execution_delay).to eq(240)
      end
    end

    context 'when the delayed_automations feature is disabled' do
      it 'rejects a payload carrying execution_delay with 422' do
        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: delayed_rule_params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(account.automation_rules.count).to eq(0)
      end

      it 'still accepts payloads without execution_delay' do
        post "/api/v1/accounts/#{account.id}/automation_rules",
             headers: administrator.create_new_auth_token,
             params: delayed_rule_params.except(:execution_delay)

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.last.execution_delay).to be_nil
      end

      it 'rejects cloning an existing delayed rule instead of turning it into an instant one' do
        automation_rule = create(:automation_rule, account: account, execution_delay: 240)

        post "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}/clone",
             headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_entity)
        expect(account.automation_rules.count).to eq(1)
      end

      it 'still clones a rule that carries no delay' do
        automation_rule = create(:automation_rule, account: account)

        post "/api/v1/accounts/#{account.id}/automation_rules/#{automation_rule.id}/clone",
             headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(account.automation_rules.count).to eq(2)
      end
    end
  end
end
