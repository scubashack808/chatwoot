require 'rails_helper'

RSpec.describe ConversationFinder do
  describe '#perform' do
    let(:account) { create(:account) }
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:inbox) { create(:inbox, account: account) }

    before do
      Current.account = account
      create(:inbox_member, user: agent, inbox: inbox)
      account.enable_features!(:email_mailbox_actions, :sla)
    end

    it 'keeps mailbox filtering compatible with Enterprise SLA preloads' do
      archived_conversation = create(:conversation, account: account, inbox: inbox)
      archived_message = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: archived_conversation,
        message_type: :incoming
      )
      archived_message.write_imap_identity!(
        Imap::MessageIdentity.build(mailbox: 'Archive', uidvalidity: 42, uid: 8, roles: ['archive'])
      )
      inbox_conversation = create(:conversation, account: account, inbox: inbox)
      inbox_message = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: inbox_conversation,
        message_type: :incoming
      )
      inbox_message.write_imap_identity!(
        Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 9, roles: ['inbox'])
      )

      result = described_class.new(agent, status: 'all', mailbox_role: 'archive').perform

      expect(result[:conversations].map(&:id)).to eq([archived_conversation.id])
    end
  end

  describe '#perform_meta_only' do
    let(:account) { create(:account) }
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:other_agent) { create(:user, account: account, role: :agent) }
    let(:inbox) { create(:inbox, account: account) }

    before do
      Current.account = account
      create(:inbox_member, user: agent, inbox: inbox)
      account.account_users.find_by(user: agent).update!(
        role: :agent,
        custom_role: create(:custom_role, account: account, permissions: %w[conversation_participating_manage])
      )
    end

    it 'counts participant-filtered conversations once when assigned conversations have multiple participants' do
      assigned_conversation = create(:conversation, account: account, inbox: inbox, assignee: agent)
      participating_conversation = create(:conversation, account: account, inbox: inbox, assignee: other_agent)
      create(:conversation, account: account, inbox: inbox, assignee: other_agent)

      2.times do
        participant = create(:user, account: account, role: :agent)
        create(:inbox_member, user: participant, inbox: inbox)
        create(:conversation_participant, account: account, conversation: assigned_conversation, user: participant)
      end
      create(:conversation_participant, account: account, conversation: participating_conversation, user: agent)

      result = described_class.new(agent, { status: 'open' }).perform_meta_only

      expect(result[:count]).to eq({
                                     mine_count: 1,
                                     assigned_count: 2,
                                     unassigned_count: 0,
                                     all_count: 2
                                   })
    end
  end
end
