require 'rails_helper'

RSpec.describe EmailMailboxOperation do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  def build_operation(**overrides)
    described_class.new({
      account: account, inbox: inbox, conversation: conversation,
      action: :archive, idempotency_key: SecureRandom.uuid
    }.merge(overrides))
  end

  describe 'constraints' do
    it 'enforces one idempotency key per account' do
      key = SecureRandom.uuid
      build_operation(idempotency_key: key).save!

      expect { build_operation(idempotency_key: key, conversation: create(:conversation, account: account, inbox: inbox)).save! }
        .to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'allows the same idempotency key in a different account' do
      key = SecureRandom.uuid
      build_operation(idempotency_key: key).save!
      other_account = create(:account)
      other_inbox = create(:channel_email, :imap_email, account: other_account).inbox

      other = described_class.new(account: other_account, inbox: other_inbox,
                                  conversation: create(:conversation, account: other_account, inbox: other_inbox),
                                  action: :archive, idempotency_key: key)

      expect(other.save).to be true
    end

    it 'allows only one nonterminal operation per conversation' do
      build_operation.save!

      expect { build_operation.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows a new operation once the previous one is terminal' do
      first = build_operation
      first.save!
      first.update!(status: :succeeded)

      expect { build_operation.save! }.not_to raise_error
    end
  end

  describe 'defaults' do
    it 'starts pending with no attempts and empty items and results' do
      operation = build_operation
      operation.save!

      expect(operation.status).to eq 'pending'
      expect(operation.attempt_count).to eq 0
      expect(operation.items).to eq []
      expect(operation.results).to eq []
    end
  end

  describe '#unresolved_items' do
    subject(:operation) do
      build_operation(items: [{ 'message_id' => 1 }, { 'message_id' => 2 }, { 'message_id' => 3 }])
    end

    it 'is everything when nothing has been recorded' do
      expect(operation.unresolved_items.pluck('message_id')).to eq [1, 2, 3]
    end

    it 'excludes messages that already succeeded, so a retry never moves them twice' do
      operation.results = [{ 'message_id' => 1, 'status' => 'succeeded' }]

      expect(operation.unresolved_items.pluck('message_id')).to eq [2, 3]
    end

    it 'still includes messages that conflicted, because those are retryable' do
      operation.results = [{ 'message_id' => 1, 'status' => 'conflict' }]

      expect(operation.unresolved_items.pluck('message_id')).to include(1)
    end
  end

  describe '#derive_status' do
    it 'succeeds when every item succeeded' do
      operation = build_operation(items: [{ 'message_id' => 1 }],
                                  results: [{ 'message_id' => 1, 'status' => 'succeeded' }])

      expect(operation.derive_status).to eq :succeeded
    end

    it 'partially succeeds when some items succeeded' do
      operation = build_operation(items: [{ 'message_id' => 1 }, { 'message_id' => 2 }],
                                  results: [{ 'message_id' => 1, 'status' => 'succeeded' },
                                            { 'message_id' => 2, 'status' => 'conflict' }])

      expect(operation.derive_status).to eq :partially_succeeded
    end

    it 'conflicts when every item conflicted' do
      operation = build_operation(items: [{ 'message_id' => 1 }],
                                  results: [{ 'message_id' => 1, 'status' => 'conflict' }])

      expect(operation.derive_status).to eq :conflict
    end

    it 'fails when nothing succeeded and it was not a pure conflict' do
      operation = build_operation(items: [{ 'message_id' => 1 }, { 'message_id' => 2 }],
                                  results: [{ 'message_id' => 1, 'status' => 'failed' },
                                            { 'message_id' => 2, 'status' => 'conflict' }])

      expect(operation.derive_status).to eq :failed
    end
  end

  describe '#summary' do
    subject(:summary) do
      build_operation(items: [{ 'message_id' => 1 }, { 'message_id' => 2 }],
                      results: [{ 'message_id' => 1, 'status' => 'succeeded' },
                                { 'message_id' => 2, 'status' => 'conflict', 'detail' => 'uid gone' }]).summary
    end

    it 'reports counts a client can render' do
      expect(summary[:total]).to eq 2
      expect(summary[:succeeded]).to eq 1
      expect(summary[:conflicted]).to eq 1
    end

    it 'carries no message body, credential or raw server text' do
      expect(summary.to_s).not_to match(/password|token|secret|body/i)
      expect(summary.keys).to contain_exactly(:id, :action, :status, :attempt_count, :error_code,
                                              :total, :succeeded, :conflicted, :failed)
    end
  end

  describe '#terminal?' do
    it 'is false while pending or running' do
      expect(build_operation(status: :pending)).not_to be_terminal
      expect(build_operation(status: :running)).not_to be_terminal
    end

    it 'is true for every settled status' do
      %i[succeeded partially_succeeded failed conflict].each do |status|
        expect(build_operation(status: status)).to be_terminal
      end
    end
  end
end
