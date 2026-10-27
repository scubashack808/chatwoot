require 'rails_helper'

RSpec.describe 'Webhooks::LineController', type: :request do
  describe 'POST /webhooks/line/{:line_channel_id}' do
    it 'call the line events job with the params' do
      allow(Webhooks::LineEventsJob).to receive(:perform_later)
      expect(Webhooks::LineEventsJob).to receive(:perform_later)
      post '/webhooks/line/line_channel_id', params: { content: 'hello' }
      expect(response).to have_http_status(:success)
    end

    context 'when LINE redelivers a signed message event' do
      let(:channel) { create(:channel_line) }
      let(:user_id) { 'U00000000000000000000000000000001' }
      let(:event) do
        {
          'type' => 'message', 'webhookEventId' => '01H810YECXQQZ37VAXPF6H9E6T',
          'deliveryContext' => { 'isRedelivery' => false }, 'timestamp' => 1_700_000_000_000,
          'source' => { 'type' => 'user', 'userId' => user_id }, 'replyToken' => 'synthetic-reply-token',
          'mode' => 'active', 'message' => { 'id' => '325708', 'type' => 'text', 'text' => 'One customer message' }
        }
      end
      let(:redelivery) { event.deep_merge('deliveryContext' => { 'isRedelivery' => true }) }

      before do
        stub_request(:get, "https://api.line.me/v2/bot/profile/#{user_id}")
          .to_return(status: 200, body: { userId: user_id, displayName: 'Synthetic customer' }.to_json,
                     headers: { 'Content-Type' => 'application/json' })
      end

      def deliver(line_event)
        body = { destination: 'U00000000000000000000000000000002', events: [line_event] }.to_json
        signature = Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', channel.line_channel_secret, body))
        perform_enqueued_jobs(only: Webhooks::LineEventsJob) do
          post "/webhooks/line/#{channel.line_channel_id}", params: body,
                                                            headers: { 'CONTENT_TYPE' => 'application/json', 'X-Line-Signature' => signature }
        end
        expect(response).to have_http_status(:ok)
      end

      it 'persists one incoming message for the original and its redelivery' do
        deliver(event)
        deliver(redelivery)

        expect(channel.inbox.messages.incoming.where(source_id: '325708').count).to eq(1)
        expect(channel.inbox.contact_inboxes.count).to eq(1)
        expect(channel.inbox.conversations.count).to eq(1)
      end
    end
  end
end
