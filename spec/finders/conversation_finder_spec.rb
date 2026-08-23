require 'rails_helper'

describe ConversationFinder do
  subject(:conversation_finder) { described_class.new(user_1, params) }

  let!(:account) { create(:account) }
  let!(:user_1) { create(:user, account: account) }
  let!(:user_2) { create(:user, account: account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let!(:contact_inbox) { create(:contact_inbox, inbox: inbox, source_id: 'testing_source_id') }
  let!(:restricted_inbox) { create(:inbox, account: account) }

  before do
    create(:inbox_member, user: user_1, inbox: inbox)
    create(:inbox_member, user: user_2, inbox: inbox)
    create(:conversation, account: account, inbox: inbox, assignee: user_1)
    create(:conversation, account: account, inbox: inbox, assignee: user_1)
    create(:conversation, account: account, inbox: inbox, assignee: user_1, status: 'resolved')
    create(:conversation, account: account, inbox: inbox, assignee: user_2, contact_inbox: contact_inbox)
    # unassigned conversation
    create(:conversation, account: account, inbox: inbox)
    Current.account = account
  end

  describe '#perform' do
    context 'with status' do
      let(:params) { { status: 'open', assignee_type: 'me' } }

      it 'filter conversations by status' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 2
      end
    end

    context 'with inbox' do
      let!(:restricted_conversation) { create(:conversation, account: account, inbox_id: restricted_inbox.id) }

      it 'returns conversation from any inbox if its admin' do
        params = { inbox_id: restricted_inbox.id }
        result = described_class.new(admin, params).perform

        expect(result[:conversations].map(&:id)).to include(restricted_conversation.id)
      end

      it 'returns conversation from inbox if agent is its member' do
        params = { inbox_id: restricted_inbox.id }
        create(:inbox_member, user: user_1, inbox: restricted_inbox)
        result = described_class.new(user_1, params).perform

        expect(result[:conversations].map(&:id)).to include(restricted_conversation.id)
      end

      it 'does not return conversations from inboxes where agent is not a member' do
        params = { inbox_id: restricted_inbox.id }
        result = described_class.new(user_1, params).perform

        expect(result[:conversations].map(&:id)).not_to include(restricted_conversation.id)
      end

      it 'returns only the conversations from the inbox if inbox_id filter is passed' do
        conversation = create(:conversation, account: account, inbox_id: inbox.id)
        params = { inbox_id: restricted_inbox.id }
        result = described_class.new(admin, params).perform

        conversation_ids = result[:conversations].map(&:id)
        expect(conversation_ids).not_to include(conversation.id)
        expect(conversation_ids).to include(restricted_conversation.id)
      end
    end

    context 'with assignee_type all' do
      let(:params) { { assignee_type: 'all' } }

      it 'filter conversations by assignee type all' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 4
      end
    end

    context 'with assignee_type unassigned' do
      let(:params) { { assignee_type: 'unassigned' } }
      let!(:agent_bot_conversation) do
        create(:conversation, account: account, inbox: inbox, assignee_agent_bot: create(:agent_bot, account: account))
      end

      it 'filter conversations by assignee type unassigned' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 1
        expect(result[:conversations]).not_to include(agent_bot_conversation)
      end
    end

    context 'with status all' do
      let(:params) { { status: 'all' } }

      it 'returns all conversations' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 5
      end
    end

    context 'with unread sort' do
      let(:params) { { status: 'open', sort_by: 'unread' } }

      it 'returns all conversations matching the selected status with the highest unread count first' do
        most_unread_conversation = create(:conversation, account: account, inbox: inbox,
                                                         agent_last_seen_at: 1.hour.ago)
        unread_conversation = create(:conversation, account: account, inbox: inbox,
                                                    agent_last_seen_at: 1.hour.ago)
        read_conversation = create(:conversation, account: account, inbox: inbox,
                                                  agent_last_seen_at: 1.minute.from_now)
        resolved_unread_conversation = create(:conversation, account: account, inbox: inbox, status: 'resolved',
                                                             agent_last_seen_at: 1.hour.ago)

        [most_unread_conversation, unread_conversation, read_conversation, resolved_unread_conversation].each do |conversation|
          create(:message, account: account, inbox: inbox, conversation: conversation,
                           message_type: :incoming, created_at: 5.minutes.ago)
        end
        create(:message, account: account, inbox: inbox, conversation: most_unread_conversation,
                         message_type: :incoming, created_at: 4.minutes.ago)
        resolved_unread_conversation.update!(status: 'resolved')
        read_conversation.update!(last_activity_at: 1.minute.from_now)
        unread_conversation.update!(last_activity_at: 2.minutes.from_now)

        result = conversation_finder.perform
        conversation_ids = result[:conversations].map(&:id)

        expect(conversation_ids).to include(most_unread_conversation.id, unread_conversation.id, read_conversation.id)
        expect(conversation_ids).not_to include(resolved_unread_conversation.id)
        expect(conversation_ids.index(most_unread_conversation.id)).to be < conversation_ids.index(unread_conversation.id)
        expect(conversation_ids.index(unread_conversation.id)).to be < conversation_ids.index(read_conversation.id)
      end

      it 'includes private incoming messages in unread counts used for ordering' do
        private_unread_conversation = create(:conversation, account: account, inbox: inbox,
                                                            agent_last_seen_at: 1.hour.ago)
        unread_conversation = create(:conversation, account: account, inbox: inbox,
                                                    agent_last_seen_at: 1.hour.ago)
        read_conversation = create(:conversation, account: account, inbox: inbox,
                                                  agent_last_seen_at: 1.minute.from_now)

        2.times do
          create(:message, account: account, inbox: inbox, conversation: private_unread_conversation,
                           message_type: :incoming, private: true, created_at: 5.minutes.ago)
        end
        create(:message, account: account, inbox: inbox, conversation: unread_conversation,
                         message_type: :incoming, created_at: 5.minutes.ago)
        create(:message, account: account, inbox: inbox, conversation: read_conversation,
                         message_type: :incoming, created_at: 5.minutes.ago)
        private_unread_conversation.update!(last_activity_at: 10.minutes.ago)
        unread_conversation.update!(last_activity_at: 2.minutes.from_now)
        read_conversation.update!(last_activity_at: 1.minute.from_now)

        result = conversation_finder.perform
        conversation_ids = result[:conversations].map(&:id)

        expect(private_unread_conversation.unread_incoming_messages.count).to eq 2
        expect(conversation_ids.index(private_unread_conversation.id)).to be < conversation_ids.index(unread_conversation.id)
        expect(conversation_ids.index(unread_conversation.id)).to be < conversation_ids.index(read_conversation.id)
      end
    end

    context 'with assignee_type assigned' do
      let(:params) { { assignee_type: 'assigned' } }
      let!(:agent_bot_conversation) do
        create(:conversation, account: account, inbox: inbox, assignee_agent_bot: create(:agent_bot, account: account))
      end

      it 'filter conversations by assignee type assigned' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 4
        expect(result[:conversations]).to include(agent_bot_conversation)
      end

      it 'returns the correct meta' do
        result = conversation_finder.perform
        expect(result[:count]).to eq({
                                       mine_count: 2,
                                       assigned_count: 4,
                                       unassigned_count: 1,
                                       all_count: 5
                                     })
      end
    end

    context 'with team' do
      let(:team) { create(:team, account: account) }
      let(:params) { { team_id: team.id } }

      it 'filter conversations by team' do
        create(:conversation, account: account, inbox: inbox, team: team)
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 1
      end
    end

    context 'with labels' do
      let(:params) { { labels: ['resolved'] } }

      it 'filter conversations by labels' do
        conversation = inbox.conversations.first
        conversation.update_labels('resolved')

        result = conversation_finder.perform
        expect(result[:conversations].length).to be 1
      end
    end

    context 'with source_id' do
      let(:params) { { source_id: 'testing_source_id' } }

      it 'filter conversations by source id' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 1
      end
    end

    context 'without source' do
      let(:params) { {} }

      it 'returns conversations with any source' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 4
      end
    end

    context 'with updated_within' do
      let(:params) { { updated_within: 20, assignee_type: 'unassigned', sort_by: 'created_at_asc' } }

      it 'filters based on params, sort order but returns all conversations without pagination with in time range' do
        # value of updated_within is in seconds
        # write spec based on that
        conversations = create_list(:conversation, 50, account: account,
                                                       inbox: inbox, assignee: nil,
                                                       updated_at: Time.now.utc - 30.seconds,
                                                       created_at: Time.now.utc - 30.seconds)
        # update updated_at of 27 conversations to be with in 20 seconds
        conversations[0..27].each do |conversation|
          conversation.update(updated_at: Time.now.utc - 10.seconds)
        end
        result = conversation_finder.perform
        # pagination is not applied
        # filters are applied
        # modified conversations + 1 conversation created during set up
        expect(result[:conversations].length).to be 29
        # ensure that the conversations are sorted by created_at
        expect(result[:conversations].first.created_at).to be < result[:conversations].last.created_at
      end
    end

    context 'with pagination' do
      let(:params) { { status: 'open', assignee_type: 'me', page: 1 } }

      it 'returns paginated conversations' do
        create_list(:conversation, 50, account: account, inbox: inbox, assignee: user_1)
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 25
      end
    end

    context 'with a mailbox role' do
      let(:params) { { status: 'all', mailbox_role: 'archive' } }

      before do
        account.enable_features!(:email_mailbox_actions)
      end

      it 'returns exactly the conversations represented in each mailbox role' do
        create_conversation = lambda do |*identities|
          conversation = create(:conversation, account: account, inbox: inbox)
          identities.each do |identity|
            message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
            message.write_imap_identity!(identity) if identity
          end
          conversation
        end
        inbox_identity = Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 1, roles: ['inbox'])
        archive_identity = Imap::MessageIdentity.build(mailbox: 'Archive', uidvalidity: 42, uid: 2, roles: ['archive'])
        gmail_inbox_identity = Imap::MessageIdentity
                               .build(mailbox: 'INBOX', uidvalidity: 42, uid: 3, roles: ['inbox'], provider_id: '9001')
                               .with_location(mailbox: '[Gmail]/All Mail', uidvalidity: 43, uid: 30, roles: ['archive'])
        gmail_archive_identity = Imap::MessageIdentity.build(
          mailbox: '[Gmail]/All Mail', uidvalidity: 43, uid: 31, roles: ['archive'], provider_id: '9002'
        )

        tracked_inbox = create_conversation.call(inbox_identity)
        standard_archive = create_conversation.call(archive_identity)
        gmail_inbox = create_conversation.call(gmail_inbox_identity)
        gmail_archive = create_conversation.call(gmail_archive_identity)
        mixed = create_conversation.call(inbox_identity, archive_identity)
        untracked = create_conversation.call(nil)
        trash = create_conversation.call(
          Imap::MessageIdentity.build(mailbox: 'Trash', uidvalidity: 42, uid: 6, roles: ['trash'])
        )
        spam = create_conversation.call(
          Imap::MessageIdentity.build(mailbox: 'Junk', uidvalidity: 42, uid: 7, roles: ['spam'])
        )

        inbox_ids = described_class.new(user_1, status: 'all', mailbox_role: 'inbox').perform[:conversations].map(&:id)
        archive_ids = described_class.new(user_1, status: 'all', mailbox_role: 'archive').perform[:conversations].map(&:id)
        trash_ids = described_class.new(user_1, status: 'all', mailbox_role: 'trash').perform[:conversations].map(&:id)
        spam_ids = described_class.new(user_1, status: 'all', mailbox_role: 'spam').perform[:conversations].map(&:id)

        expect(inbox_ids).to contain_exactly(tracked_inbox.id, gmail_inbox.id, mixed.id, untracked.id)
        expect(archive_ids).to contain_exactly(standard_archive.id, gmail_archive.id, mixed.id)
        expect(trash_ids).to contain_exactly(trash.id)
        expect(spam_ids).to contain_exactly(spam.id)
      end

      it 'applies server sorting after mailbox filtering' do
        older_archive = create(
          :conversation, account: account, inbox: inbox, last_activity_at: 3.hours.ago, created_at: 3.hours.ago
        )
        newer_archive = create(
          :conversation, account: account, inbox: inbox, last_activity_at: 1.hour.ago, created_at: 1.hour.ago
        )
        non_archive = create(
          :conversation, account: account, inbox: inbox, last_activity_at: 2.hours.ago, created_at: 2.hours.ago
        )
        [[older_archive, 'archive'], [newer_archive, 'archive'], [non_archive, 'inbox']].each_with_index do |(conversation, role), index|
          message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
          message.write_imap_identity!(
            Imap::MessageIdentity.build(mailbox: role.titleize, uidvalidity: 42, uid: index + 1, roles: [role])
          )
        end

        result = described_class.new(
          user_1,
          status: 'all',
          mailbox_role: 'archive',
          sort_by: 'last_activity_at_asc'
        ).perform

        expect(result[:conversations].map(&:id)).to eq([older_archive.id, newer_archive.id])
      end

      it 'keeps counts and every page boundary correct after mailbox filtering' do
        archives = Array.new(5) do |index|
          conversation = create(
            :conversation,
            account: account,
            inbox: inbox,
            created_at: (5 - index).hours.ago,
            last_activity_at: (5 - index).hours.ago
          )
          message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
          message.write_imap_identity!(
            Imap::MessageIdentity.build(mailbox: 'Archive', uidvalidity: 42, uid: index + 1, roles: ['archive'])
          )
          conversation
        end
        non_archive = create(:conversation, account: account, inbox: inbox)
        create(:message, account: account, inbox: inbox, conversation: non_archive, message_type: :incoming)

        results = with_modified_env CONVERSATION_RESULTS_PER_PAGE: '2' do
          (1..4).map do |page|
            described_class.new(
              user_1,
              status: 'all',
              mailbox_role: 'archive',
              sort_by: 'created_at_asc',
              page: page
            ).perform
          end
        end

        expect(results.map { |result| result[:conversations].map(&:id) }).to eq(
          [archives.first(2).map(&:id), archives.drop(2).first(2).map(&:id), [archives.last.id], []]
        )
        expect(results.map { |result| result.dig(:count, :all_count) }).to eq([5, 5, 5, 5])
      end
    end

    # M07: "Chatwoot and threadable external outgoing messages appear; Inbox membership is
    # independent." The Sent view keeps the conversation-centric meaning it always had, clarified
    # so that a reply sent from another client and imported by the Sent patch counts too.
    context 'with the sent mailbox role' do
      let(:params) { { status: 'all', mailbox_role: 'sent' } }

      before do
        account.enable_features!(:email_mailbox_actions)
      end

      it 'lists conversations with a Chatwoot outgoing message and with an imported external one' do
        chatwoot_sent = create(:conversation, account: account, inbox: inbox)
        create(:message, account: account, inbox: inbox, conversation: chatwoot_sent,
                         message_type: :outgoing, source_id: 'chatwoot-send@example.test')

        external_sent = create(:conversation, account: account, inbox: inbox)
        imported = create(:message, account: account, inbox: inbox, conversation: external_sent,
                                    message_type: :outgoing, source_id: 'from-phone@example.test')
        imported.write_imap_identity!(
          Imap::MessageIdentity.build(mailbox: 'INBOX.SentItems', uidvalidity: 7001, uid: 9, roles: ['sent'])
        )

        # Both of these carry a source_id, exactly as real ingested and real sent mail does, so
        # that the outgoing and the not-private halves of the rule are each genuinely exercised
        # rather than passing because source_id happened to be nil.
        incoming_only = create(:conversation, account: account, inbox: inbox)
        create(:message, account: account, inbox: inbox, conversation: incoming_only,
                         message_type: :incoming, source_id: 'customer-mail@example.test')

        private_note_only = create(:conversation, account: account, inbox: inbox)
        create(:message, account: account, inbox: inbox, conversation: private_note_only,
                         message_type: :outgoing, private: true, source_id: 'private-note@example.test')

        sent_ids = described_class.new(user_1, status: 'all', mailbox_role: 'sent').perform[:conversations].map(&:id)

        expect(sent_ids).to include(chatwoot_sent.id, external_sent.id)
        expect(sent_ids).not_to include(incoming_only.id, private_note_only.id)
      end

      it 'keeps Inbox membership independent of Sent membership' do
        both = create(:conversation, account: account, inbox: inbox)
        incoming = create(:message, account: account, inbox: inbox, conversation: both, message_type: :incoming)
        incoming.write_imap_identity!(
          Imap::MessageIdentity.build(mailbox: 'INBOX', uidvalidity: 42, uid: 1, roles: ['inbox'])
        )
        outgoing = create(:message, account: account, inbox: inbox, conversation: both,
                                    message_type: :outgoing, source_id: 'reply@example.test')
        outgoing.write_imap_identity!(
          Imap::MessageIdentity.build(mailbox: 'INBOX.SentItems', uidvalidity: 7001, uid: 2, roles: ['sent'])
        )

        inbox_ids = described_class.new(user_1, status: 'all', mailbox_role: 'inbox').perform[:conversations].map(&:id)
        sent_ids = described_class.new(user_1, status: 'all', mailbox_role: 'sent').perform[:conversations].map(&:id)

        expect(inbox_ids).to include(both.id)
        expect(sent_ids).to include(both.id)
        expect(Imap::ConversationMailboxState.new(conversation: both).to_h[:state]).to eq 'inbox'
      end

      it 'ignores the sent role entirely while the mailbox feature is off, exactly as the other roles do' do
        account.disable_features!(:email_mailbox_actions)
        conversation = create(:conversation, account: account, inbox: inbox)
        create(:message, account: account, inbox: inbox, conversation: conversation,
                         message_type: :outgoing, source_id: 'chatwoot-send@example.test')

        result = described_class.new(user_1, status: 'all', mailbox_role: 'sent').perform

        expect(result[:conversations].map(&:id)).to include(conversation.id)
      end
    end

    context 'with perform_meta_only' do
      let(:params) { { assignee_type: 'assigned' } }

      it 'returns only count without conversations' do
        result = conversation_finder.perform_meta_only
        expect(result).to have_key(:count)
        expect(result).not_to have_key(:conversations)
      end

      it 'returns the correct counts' do
        result = conversation_finder.perform_meta_only
        expect(result[:count]).to eq({
                                       mine_count: 2,
                                       assigned_count: 3,
                                       unassigned_count: 1,
                                       all_count: 4
                                     })
      end

      it 'returns same counts as perform' do
        meta_result = conversation_finder.perform_meta_only
        full_result = conversation_finder.perform
        expect(meta_result[:count]).to eq(full_result[:count])
      end
    end

    context 'with unattended' do
      let(:params) { { status: 'open', assignee_type: 'me', conversation_type: 'unattended' } }

      it 'returns unattended conversations' do
        create(:conversation, account: account, first_reply_created_at: Time.now.utc, assignee: user_1) # attended_conversation
        create(:conversation, account: account, first_reply_created_at: nil, assignee: user_1) # unattended_conversation_no_first_reply
        create(:conversation, account: account, first_reply_created_at: Time.now.utc,
                              assignee: user_1, waiting_since: Time.now.utc) # unattended_conversation_waiting_since

        result = conversation_finder.perform
        expect(result[:conversations].length).to be 2
      end
    end

    context 'with participating' do
      let(:params) { { status: 'open', assignee_type: 'all', conversation_type: 'participating' } }

      it 'excludes participating conversations from inboxes the user no longer has access to' do
        accessible_conversation = create(:conversation, account: account, inbox: inbox)
        revoked_conversation = create(:conversation, account: account, inbox: restricted_inbox)
        revoked_membership = create(:inbox_member, user: user_1, inbox: restricted_inbox)
        create(:conversation_participant, user: user_1, conversation: accessible_conversation, account: account)
        create(:conversation_participant, user: user_1, conversation: revoked_conversation, account: account)
        revoked_membership.destroy!

        result = conversation_finder.perform

        expect(result[:conversations].map(&:id)).to contain_exactly(accessible_conversation.id)
      end

      it 'excludes the inaccessible conversation from the meta counts too' do
        accessible_conversation = create(:conversation, account: account, inbox: inbox)
        revoked_conversation = create(:conversation, account: account, inbox: restricted_inbox)
        revoked_membership = create(:inbox_member, user: user_1, inbox: restricted_inbox)
        create(:conversation_participant, user: user_1, conversation: accessible_conversation, account: account)
        create(:conversation_participant, user: user_1, conversation: revoked_conversation, account: account)
        revoked_membership.destroy!

        result = conversation_finder.perform_meta_only

        expect(result[:count][:all_count]).to eq 1
      end
    end
  end
end
