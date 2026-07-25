require 'rails_helper'

RSpec.describe EmailMailboxOperationJob do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_email, :imap_email, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:operation) do
    create(
      :email_mailbox_operation,
      account: account,
      inbox: inbox,
      conversation: conversation,
      status: :pending,
      items: [{ 'message_id' => 1 }]
    )
  end
  let(:executor) { instance_double(Imap::MailboxOperationExecutor, perform: operation) }

  before do
    allow(Imap::MailboxOperationExecutor).to receive(:new).with(operation: operation).and_return(executor)
  end

  it 'executes a pending durable operation' do
    described_class.perform_now(operation.id)

    expect(executor).to have_received(:perform)
  end

  it 'reschedules the same operation after inbox lease contention' do
    allow(executor).to receive(:perform).and_raise(Imap::Lease::LeaseNotAcquiredError)

    expect { described_class.perform_now(operation.id) }
      .to have_enqueued_job(described_class).with(operation.id)
  end

  it 'does not rerun a terminal operation until the guarded API marks it pending' do
    operation.update!(status: :partially_succeeded)

    described_class.perform_now(operation.id)

    expect(executor).not_to have_received(:perform)
  end
end
