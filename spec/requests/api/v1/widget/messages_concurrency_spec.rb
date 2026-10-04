require 'rails_helper'

RSpec.describe 'Concurrent widget sends', type: :request do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:web_widget) { create(:channel_widget, account: account) }
  let(:inbox) { web_widget.inbox }
  let(:contact) { create(:contact, account: account, email: nil) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:token) { Widget::TokenService.new(payload: { source_id: contact_inbox.source_id, inbox_id: inbox.id }).generate_token }

  before do
    inbox.update!(enable_auto_assignment: false, greeting_enabled: false, enable_email_collect: false)
    contact_inbox
  end

  after do
    connection = ActiveRecord::Base.connection
    connection.truncate_tables(*connection.tables)
  end

  def post_widget(content)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.post "/api/v1/widget/messages?website_token=#{web_widget.website_token}",
                 params: { message: { content: content } }, headers: { 'X-Auth-Token' => token }, as: :json
    session.response.status
  end

  def widget_history
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.get "/api/v1/widget/messages?website_token=#{web_widget.website_token}", headers: { 'X-Auth-Token' => token }, as: :json
    session.response.parsed_body['payload'].pluck('content')
  end

  # Each thread posts on its own committed PostgreSQL connection.
  def in_two_threads(&)
    ActiveRecord::Base.connection_pool.release_connection
    backend_pids = Concurrent::Array.new
    threads = Array.new(2) do |number|
      Thread.new do
        Rails.application.executor.wrap do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            backend_pids << connection.raw_connection.backend_pid
            yield number
          end
        end
      end
    end
    results = threads.map { |thread| thread.join(45).value }
    expect(backend_pids.uniq.size).to eq(2)
    results
  end

  it 'puts overlapping first sends in one conversation and returns both in history' do
    barrier = Concurrent::CyclicBarrier.new(2)
    # Each request builds its own controller instance, so the seam must be stubbed on any instance.
    # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(Api::V1::Widget::MessagesController).to receive(:create_first_conversation).and_wrap_original do |original|
      # Both requests have already found no conversation; release them together.
      expect(ActiveSupport::Dependencies.interlock.permit_concurrent_loads { barrier.wait(15) }).to be(true)
      original.call
    end
    # rubocop:enable RSpec/AnyInstance

    statuses = in_two_threads { |number| post_widget("First send #{number}") }

    expect(statuses).to eq([200, 200])
    expect(contact_inbox.conversations.count).to eq(1)
    expect(contact_inbox.conversations.sole.messages.incoming.pluck(:content)).to contain_exactly('First send 0', 'First send 1')
    expect(widget_history).to include('First send 0', 'First send 1')
  end

  it 'keeps sequential first sends in one conversation' do
    statuses = Array.new(2) { |number| post_widget("Sequential send #{number}") }

    expect(statuses).to eq([200, 200])
    expect(contact_inbox.conversations.sole.messages.incoming.pluck(:content)).to contain_exactly('Sequential send 0', 'Sequential send 1')
  end

  it 'keeps overlapping sends in an existing conversation' do
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)

    statuses = in_two_threads { |number| post_widget("Existing send #{number}") }

    expect(statuses).to eq([200, 200])
    expect(contact_inbox.conversations.sole).to eq(conversation)
    expect(conversation.messages.incoming.pluck(:content)).to contain_exactly('Existing send 0', 'Existing send 1')
  end
end
