require 'rails_helper'

RSpec.describe Webhooks::WhatsappEventsJob do
  subject(:job) { described_class }

  let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
  let(:params)  do
    {
      object: 'whatsapp_business_account',
      phone_number: channel.phone_number,
      entry: [{
        changes: [
          {
            value: {
              metadata: {
                phone_number_id: channel.provider_config['phone_number_id'],
                display_phone_number: channel.phone_number.delete('+')
              }
            }
          }
        ]
      }]
    }
  end
  let(:process_service) { double }

  before do
    allow(process_service).to receive(:perform)
  end

  it 'enqueues the job' do
    expect { job.perform_later(params) }.to have_enqueued_job(described_class)
      .with(params)
      .on_queue('low')
  end

  # Run serially with an explicitly supplied, disposable test Redis server, never a shared Redis target.
  context 'with real Redis attachment replay' do
    let(:redis_url) { ENV.fetch('WHATSAPP_REPLAY_TEST_REDIS_URL') }
    let(:namespace) { "whatsapp_replay_#{SecureRandom.hex(16)}" }
    let(:owned_keys) { Set.new }
    let(:owned_keys_mutex) { Mutex.new }
    let(:source_id) { "wamid.replay.#{SecureRandom.hex(16)}" }
    let(:source_key) { format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: source_id) }
    let(:sender_id) { '15550000002' }
    let(:mutex_key) { format(Redis::RedisKeys::WHATSAPP_MESSAGE_MUTEX, inbox_id: channel.inbox.id, sender_id: sender_id) }
    let(:media_url) { 'https://synthetic-media.invalid/image.png' }
    let(:observed_namespace_class) do
      keys = owned_keys
      mutex = owned_keys_mutex
      # Namespace copies used by transactions share the observer; no Redis commands are replaced.
      Class.new(Redis::Namespace) do
        define_method(:add_namespace) do |key|
          super(key).tap do |namespaced_key|
            mutex.synchronize { keys.add(namespaced_key) } if namespaced_key.is_a?(String) && !namespaced_key.match?(/[*?\[\]]/)
          end
        end
        private :add_namespace
      end
    end
    let(:real_pool) do
      ConnectionPool.new(size: 2, timeout: 2) do
        observed_namespace_class.new(namespace, redis: Redis.new(url: redis_url, reconnect_attempts: 0), warning: true)
      end
    end

    # Alfred's application entry point is a global pool; restore it before any cleanup can fail.
    # rubocop:disable Style/GlobalVars
    around do |example|
      skip 'Set WHATSAPP_REPLAY_TEST_REDIS_URL to an authorized disposable test Redis server' if ENV['WHATSAPP_REPLAY_TEST_REDIS_URL'].blank?
      raise 'Real Redis attachment replay requires Rails test mode' unless Rails.env.test?

      original_pool = $alfred
      begin
        $alfred = real_pool
        real_pool.with { |connection| raise 'Expected a real Redis client' unless connection.redis.instance_of?(Redis) }
        example.run
      ensure
        $alfred = original_pool
        begin
          real_pool.with do |connection|
            owned_keys.each do |key|
              raise "Unexpected cleanup key #{key.inspect}" unless key.start_with?("#{namespace}:") && !key.match?(/[*?\[\]]/)

              connection.redis.del(key)
            end
            raise 'Owned Redis keys remain after cleanup' if owned_keys.any? { |key| connection.redis.exists?(key) }
          end
        ensure
          real_pool.shutdown { |connection| connection.redis.close }
        end
      end
    end
    # rubocop:enable Style/GlobalVars

    it 'replays a download timeout and preserves successful deduplication and the contact mutex' do
      payload = params.deep_dup.with_indifferent_access
      value = payload[:entry].first[:changes].first[:value]
      value[:contacts] = [{ wa_id: sender_id, profile: { name: 'Synthetic Sender' } }]
      value[:messages] = [{ from: sender_id, id: source_id, timestamp: Time.current.to_i.to_s, type: 'image',
                            image: { id: 'synthetic-media-id', mime_type: 'image/png', caption: 'Synthetic attachment' } }]
      metadata_request = stub_request(:get, channel.media_url('synthetic-media-id')).to_return do
        expect(Redis::Alfred.ttl(mutex_key)).to be_between(1, 30)
        expect(Redis::Alfred.ttl(source_key)).to be_between(86_000, 86_400)
        {
          status: 200, body: { url: media_url, mime_type: 'image/png', id: 'synthetic-media-id' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
      download = stub_request(:get, media_url).to_return do
        aggregate_failures 'both locks are held during the real download path' do
          expect(Redis::Alfred.ttl(source_key)).to be_between(86_000, 86_400)
          expect(Redis::Alfred.ttl(mutex_key)).to be_between(1, 30)
        end
        raise Down::TimeoutError, 'Synthetic media download timeout'
      end
      messages = channel.inbox.messages.where(source_id: source_id)

      expect { job.perform_now(payload.deep_dup) }.to raise_error(Down::TimeoutError)
      aggregate_failures 'failed download rolls back and releases both keys' do
        expect(messages.count).to eq(0)
        expect(channel.inbox.conversations.count).to eq(0)
        expect(Attachment.where(account_id: channel.account_id).count).to eq(0)
        expect(Redis::Alfred.exists?(source_key)).to be(false)
        expect(Redis::Alfred.exists?(mutex_key)).to be(false)
      end

      remove_request_stub(download)
      successful_download = stub_request(:get, media_url).to_return(
        status: 200, body: File.binread(Rails.root.join('spec/assets/sample.png')), headers: { 'Content-Type' => 'image/png' }
      )
      job.perform_now(payload.deep_dup)
      aggregate_failures 'replay persists one attachment and retains deduplication' do
        expect(messages.count).to eq(1)
        expect(messages.first.attachments.count).to eq(1)
        expect(Redis::Alfred.ttl(source_key)).to be_between(86_000, 86_400)
        expect(Redis::Alfred.exists?(mutex_key)).to be(false)
      end

      job.perform_now(payload.deep_dup)
      aggregate_failures 'successful replay makes no further media requests' do
        expect(messages.count).to eq(1)
        expect(messages.first.attachments.count).to eq(1)
        expect(metadata_request).to have_been_requested.twice
        # WebMock counts the initial timeout as well as the single successful download.
        expect(successful_download).to have_been_requested.twice
        expect(Redis::Alfred.exists?(mutex_key)).to be(false)
      end
    end

    it 'only releases the owned source claim, allowing a later acquisition' do
      owner = Whatsapp::MessageDedupLock.new(source_id)
      contender = Whatsapp::MessageDedupLock.new(source_id)
      expect(owner.acquire!).to be(true)
      token = Redis::Alfred.get(source_key)
      expect(Redis::Alfred.ttl(source_key)).to be_between(86_000, 86_400)
      expect(contender.acquire!).to be(false)
      contender.release!
      expect(Redis::Alfred.get(source_key)).to eq(token)
      owner.release!
      expect(Redis::Alfred.exists?(source_key)).to be(false)
      expect(contender.acquire!).to be(true)
      replacement = Redis::Alfred.get(source_key)
      owner.release!
      expect(Redis::Alfred.get(source_key)).to eq(replacement)
    end

    it 'does not release a replacement after the original claim expires' do
      owner = Whatsapp::MessageDedupLock.new(source_id, ttl: 1)
      expect(owner.acquire!).to be(true)
      original_token = Redis::Alfred.get(source_key)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep 0.02 while Redis::Alfred.exists?(source_key) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      expect(Redis::Alfred.exists?(source_key)).to be(false)
      replacement = Whatsapp::MessageDedupLock.new(source_id)
      expect(replacement.acquire!).to be(true)
      replacement_token = Redis::Alfred.get(source_key)
      expect(replacement_token).not_to eq(original_token)
      owner.release!
      expect(Redis::Alfred.get(source_key)).to eq(replacement_token)
    end

    it 'allows exactly one of two simultaneous source claim contenders' do
      ready = Queue.new
      start = Queue.new
      contenders = Array.new(2) { Whatsapp::MessageDedupLock.new(source_id) }
      threads = contenders.map do |contender|
        Thread.new do
          real_pool.with do
            ready << true
            start.pop
            contender.acquire!
          end
        end
      end
      2.times { ready.pop }
      2.times { start << true }
      expect(threads.map(&:value).sort_by(&:to_s)).to eq([false, true])
      expect(Redis::Alfred.ttl(source_key)).to be_between(86_000, 86_400)
    ensure
      threads&.each(&:join)
    end

    it 'preserves the replacement when a real WATCH conflict aborts release' do
      owner = Whatsapp::MessageDedupLock.new(source_id)
      expect(owner.acquire!).to be(true)
      replacement_token = SecureRandom.hex(16)
      other_connection = observed_namespace_class.new(namespace, redis: Redis.new(url: redis_url, reconnect_attempts: 0))
      real_pool.with do |connection|
        expect(connection).to receive(:multi).and_wrap_original do |original, &block|
          other_connection.set(source_key, replacement_token, ex: 60)
          result = original.call(&block)
          expect(result).to be_nil
          result
        end
        owner.release!
      end
      expect(Redis::Alfred.get(source_key)).to eq(replacement_token)
    ensure
      other_connection&.redis&.close
    end
  end

  context 'when whatsapp_cloud provider' do
    it 'enqueue Whatsapp::IncomingMessageWhatsappCloudService' do
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)
      job.perform_now(params)
    end

    it 'will not enqueue message jobs based on phone number in the URL if the entry payload is not present' do
      params = {
        object: 'whatsapp_business_account',
        phone_number: channel.phone_number,
        entry: [{ changes: [{}] }]
      }
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)
      allow(Whatsapp::IncomingMessageService).to receive(:new)

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)
      expect(Whatsapp::IncomingMessageService).not_to receive(:new)
      job.perform_now(params)
    end

    it 'will not enqueue Whatsapp::IncomingMessageWhatsappCloudService if channel reauthorization required' do
      channel.prompt_reauthorization!
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)
      job.perform_now(params)
    end

    it 'still enqueues for manual channels even when reauthorization required' do
      channel.update!(provider_config: channel.provider_config.merge('source' => 'manual'))
      channel.prompt_reauthorization!
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)
      job.perform_now(params)
    end

    it 'will not enqueue if channel is not present' do
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      allow(Whatsapp::IncomingMessageService).to receive(:new).and_return(process_service)

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)
      expect(Whatsapp::IncomingMessageService).not_to receive(:new)
      job.perform_now(phone_number: 'random_phone_number')
    end

    it 'will not enqueue Whatsapp::IncomingMessageWhatsappCloudService if account is suspended' do
      account = channel.account
      account.update!(status: :suspended)
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      allow(Whatsapp::IncomingMessageService).to receive(:new).and_return(process_service)

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)
      expect(Whatsapp::IncomingMessageService).not_to receive(:new)
      job.perform_now(params)
    end

    it 'logs a warning when channel is inactive' do
      channel.prompt_reauthorization!
      allow(Rails.logger).to receive(:warn)

      expect(Rails.logger).to receive(:warn).with("Inactive WhatsApp channel: #{channel.phone_number}")
      job.perform_now(params)
    end

    it 'logs a warning with unknown phone number when channel does not exist' do
      unknown_phone = '+1234567890'
      allow(Rails.logger).to receive(:warn)

      expect(Rails.logger).to receive(:warn).with("Inactive WhatsApp channel: unknown - #{unknown_phone}")
      job.perform_now(phone_number: unknown_phone)
    end

    it 'uses from_user_id as the mutex sender for BSUID-only inbound messages' do
      bsuid = 'IN.2081978709342942'
      wb_params = params.deep_dup
      wb_params[:entry].first[:changes].first[:value][:messages] = [
        { from: '', from_user_id: bsuid, id: 'wamid-test', text: { body: 'Hello' }, type: 'text' }
      ]
      job_instance = described_class.new
      mutex_key = format(Redis::Alfred::WHATSAPP_MESSAGE_MUTEX, inbox_id: channel.inbox.id, sender_id: bsuid)

      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(job_instance).to receive(:with_lock).with(mutex_key, 30.seconds).and_yield

      job_instance.perform(wb_params)
    end

    it 'prefers from_user_id as the mutex sender for mixed phone and BSUID inbound messages' do
      bsuid = 'IN.2081978709342942'
      wb_params = params.deep_dup
      wb_params[:entry].first[:changes].first[:value][:messages] = [
        { from: '919745786257', from_user_id: bsuid, id: 'wamid-test', text: { body: 'Hello' }, type: 'text' }
      ]
      job_instance = described_class.new
      mutex_key = format(Redis::Alfred::WHATSAPP_MESSAGE_MUTEX, inbox_id: channel.inbox.id, sender_id: bsuid)

      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(job_instance).to receive(:with_lock).with(mutex_key, 30.seconds).and_yield

      job_instance.perform(wb_params)
    end

    it 'uses contact user_id as the mutex sender when message from_user_id is missing' do
      bsuid = 'IN.2081978709342942'
      wb_params = params.deep_dup
      wb_params[:entry].first[:changes].first[:value][:contacts] = [
        { profile: { name: 'Muhsin' }, wa_id: '919745786257', user_id: bsuid }
      ]
      wb_params[:entry].first[:changes].first[:value][:messages] = [
        { from: '919745786257', id: 'wamid-test', text: { body: 'Hello' }, type: 'text' }
      ]
      job_instance = described_class.new
      mutex_key = format(Redis::Alfred::WHATSAPP_MESSAGE_MUTEX, inbox_id: channel.inbox.id, sender_id: bsuid)

      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(job_instance).to receive(:with_lock).with(mutex_key, 30.seconds).and_yield

      job_instance.perform(wb_params)
    end

    it 'prefers parent BSUID as the mutex sender for inbound messages with both identifiers' do
      bsuid = 'IN.2081978709342942'
      parent_bsuid = 'IN.ENT.9081726354'
      wb_params = params.deep_dup
      wb_params[:entry].first[:changes].first[:value][:contacts] = [
        { profile: { name: 'Muhsin' }, user_id: bsuid, parent_user_id: parent_bsuid }
      ]
      wb_params[:entry].first[:changes].first[:value][:messages] = [
        { from_user_id: bsuid, from_parent_user_id: parent_bsuid, id: 'wamid-test', text: { body: 'Hello' }, type: 'text' }
      ]
      job_instance = described_class.new
      mutex_key = format(Redis::Alfred::WHATSAPP_MESSAGE_MUTEX, inbox_id: channel.inbox.id, sender_id: parent_bsuid)

      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(job_instance).to receive(:with_lock).with(mutex_key, 30.seconds).and_yield

      job_instance.perform(wb_params)
    end

    it 'uses to_user_id as the mutex sender for BSUID-only echo messages' do
      bsuid = 'IN.2081978709342942'
      wb_params = params.deep_dup
      wb_params[:entry].first[:changes].first[:field] = 'smb_message_echoes'
      wb_params[:entry].first[:changes].first[:value][:message_echoes] = [
        { from: channel.phone_number.delete('+'), to: '', to_user_id: bsuid, id: 'wamid-test', text: { body: 'Hello' }, type: 'text' }
      ]
      job_instance = described_class.new
      mutex_key = format(Redis::Alfred::WHATSAPP_MESSAGE_MUTEX, inbox_id: channel.inbox.id, sender_id: bsuid)

      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(job_instance).to receive(:with_lock).with(mutex_key, 30.seconds).and_yield

      job_instance.perform(wb_params)
    end

    it 'prefers parent BSUID as the mutex sender for echo messages with both identifiers' do
      bsuid = 'IN.2081978709342942'
      parent_bsuid = 'IN.ENT.9081726354'
      wb_params = params.deep_dup
      wb_params[:entry].first[:changes].first[:field] = 'smb_message_echoes'
      wb_params[:entry].first[:changes].first[:value][:message_echoes] = [
        {
          from: channel.phone_number.delete('+'), to: '919745786257', to_user_id: bsuid, to_parent_user_id: parent_bsuid,
          id: 'wamid-test', text: { body: 'Hello' }, type: 'text'
        }
      ]
      job_instance = described_class.new
      mutex_key = format(Redis::Alfred::WHATSAPP_MESSAGE_MUTEX, inbox_id: channel.inbox.id, sender_id: parent_bsuid)

      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(job_instance).to receive(:with_lock).with(mutex_key, 30.seconds).and_yield

      job_instance.perform(wb_params)
    end

    it 'prefers to_user_id as the mutex sender for mixed phone and BSUID echo messages' do
      bsuid = 'IN.2081978709342942'
      wb_params = params.deep_dup
      wb_params[:entry].first[:changes].first[:field] = 'smb_message_echoes'
      wb_params[:entry].first[:changes].first[:value][:message_echoes] = [
        { from: channel.phone_number.delete('+'), to: '919745786257', to_user_id: bsuid, id: 'wamid-test', text: { body: 'Hello' },
          type: 'text' }
      ]
      job_instance = described_class.new
      mutex_key = format(Redis::Alfred::WHATSAPP_MESSAGE_MUTEX, inbox_id: channel.inbox.id, sender_id: bsuid)

      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(job_instance).to receive(:with_lock).with(mutex_key, 30.seconds).and_yield

      job_instance.perform(wb_params)
    end
  end

  context 'when default provider' do
    it 'enqueue Whatsapp::IncomingMessageService' do
      stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook')
      channel.update(provider: 'default')
      allow(Whatsapp::IncomingMessageService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageService).to receive(:new)
      job.perform_now(params)
    end
  end

  context 'when whatsapp business params' do
    it 'enqueue Whatsapp::IncomingMessageWhatsappCloudService based on the number in payload' do
      other_channel = create(:channel_whatsapp, phone_number: '+1987654', provider: 'whatsapp_cloud', sync_templates: false,
                                                validate_provider_config: false)
      wb_params = {
        phone_number: channel.phone_number,
        object: 'whatsapp_business_account',
        entry: [
          {
            changes: [
              {
                value: {
                  metadata: {
                    phone_number_id: other_channel.provider_config['phone_number_id'],
                    display_phone_number: other_channel.phone_number.delete('+')
                  }
                }
              }
            ]
          }
        ]
      }
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).with(inbox: other_channel.inbox, params: wb_params)
      job.perform_now(wb_params)
    end

    it 'Ignore reaction type message and stop raising error' do
      other_channel = create(:channel_whatsapp, phone_number: '+1987654', provider: 'whatsapp_cloud', sync_templates: false,
                                                validate_provider_config: false)
      wb_params = {
        phone_number: channel.phone_number,
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              contacts: [{ profile: { name: 'Test Test' }, wa_id: '1111981136571' }],
              messages: [{
                from: '1111981136571', reaction: { emoji: '👍' }, timestamp: '1664799904', type: 'reaction'
              }],
              metadata: {
                phone_number_id: other_channel.provider_config['phone_number_id'],
                display_phone_number: other_channel.phone_number.delete('+')
              }
            }
          }]
        }]
      }.with_indifferent_access
      expect do
        Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: other_channel.inbox, params: wb_params).perform
      end.not_to change(Message, :count)
    end

    it 'ignore reaction type message, would not create contact if the reaction is the first event' do
      other_channel = create(:channel_whatsapp, phone_number: '+1987654', provider: 'whatsapp_cloud', sync_templates: false,
                                                validate_provider_config: false)
      wb_params = {
        phone_number: channel.phone_number,
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              contacts: [{ profile: { name: 'Test Test' }, wa_id: '1111981136571' }],
              messages: [{
                from: '1111981136571', reaction: { emoji: '👍' }, timestamp: '1664799904', type: 'reaction'
              }],
              metadata: {
                phone_number_id: other_channel.provider_config['phone_number_id'],
                display_phone_number: other_channel.phone_number.delete('+')
              }
            }
          }]
        }]
      }.with_indifferent_access
      expect do
        Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: other_channel.inbox, params: wb_params).perform
      end.not_to change(Contact, :count)
    end

    it 'ignore request_welcome type message, would not create contact or conversation' do
      other_channel = create(:channel_whatsapp, phone_number: '+1987654', provider: 'whatsapp_cloud', sync_templates: false,
                                                validate_provider_config: false)
      wb_params = {
        phone_number: channel.phone_number,
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              messages: [{
                from: '1111981136571', timestamp: '1664799904', type: 'request_welcome'
              }],
              metadata: {
                phone_number_id: other_channel.provider_config['phone_number_id'],
                display_phone_number: other_channel.phone_number.delete('+')
              }
            }
          }]
        }]
      }.with_indifferent_access
      expect do
        Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: other_channel.inbox, params: wb_params).perform
      end.not_to change(Contact, :count)

      expect do
        Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: other_channel.inbox, params: wb_params).perform
      end.not_to change(Conversation, :count)
    end

    it 'finds channel using normalized Brazil phone number when display_phone_number is missing the 9 digit' do
      brazil_channel = create(:channel_whatsapp, phone_number: '+5541999887766', provider: 'whatsapp_cloud',
                                                 sync_templates: false, validate_provider_config: false)
      wb_params = {
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              metadata: {
                phone_number_id: brazil_channel.provider_config['phone_number_id'],
                display_phone_number: '554199887766'
              }
            }
          }]
        }]
      }
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).with(inbox: brazil_channel.inbox, params: wb_params)
      job.perform_now(wb_params)
    end

    it 'finds channel using normalized Argentina phone number when display_phone_number has extra 9 digit' do
      argentina_channel = create(:channel_whatsapp, phone_number: '+541112345678', provider: 'whatsapp_cloud',
                                                    sync_templates: false, validate_provider_config: false)
      wb_params = {
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              metadata: {
                phone_number_id: argentina_channel.provider_config['phone_number_id'],
                display_phone_number: '5491112345678'
              }
            }
          }]
        }]
      }
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).with(inbox: argentina_channel.inbox, params: wb_params)
      job.perform_now(wb_params)
    end

    it 'finds channel when display_phone_number contains formatting characters' do
      formatted_channel = create(:channel_whatsapp, phone_number: '+14155552671', provider: 'whatsapp_cloud',
                                                    sync_templates: false, validate_provider_config: false)
      wb_params = {
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              metadata: {
                phone_number_id: formatted_channel.provider_config['phone_number_id'],
                display_phone_number: '+1 415-555-2671'
              }
            }
          }]
        }]
      }
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).with(inbox: formatted_channel.inbox, params: wb_params)
      job.perform_now(wb_params)
    end

    it 'prefers the phone_number_id match when a raw display_phone_number collision exists' do
      normalized_channel = create(:channel_whatsapp, phone_number: '+5541999887766', provider: 'whatsapp_cloud',
                                                     sync_templates: false, validate_provider_config: false)
      create(:channel_whatsapp, phone_number: '+554199887766', provider: 'whatsapp_cloud',
                                sync_templates: false, validate_provider_config: false).tap do |raw_channel|
        raw_channel.update!(provider_config: raw_channel.provider_config.merge('phone_number_id' => 'other-id'))
      end
      wb_params = {
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              metadata: {
                phone_number_id: normalized_channel.provider_config['phone_number_id'],
                display_phone_number: '554199887766'
              }
            }
          }]
        }]
      }
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).with(inbox: normalized_channel.inbox, params: wb_params)
      job.perform_now(wb_params)
    end

    it 'will not enque Whatsapp::IncomingMessageWhatsappCloudService when invalid phone number id' do
      other_channel = create(:channel_whatsapp, phone_number: '+1987654', provider: 'whatsapp_cloud', sync_templates: false,
                                                validate_provider_config: false)
      wb_params = {
        phone_number: channel.phone_number,
        object: 'whatsapp_business_account',
        entry: [
          {
            changes: [
              {
                value: {
                  metadata: {
                    phone_number_id: 'random phone number id',
                    display_phone_number: other_channel.phone_number.delete('+')
                  }
                }
              }
            ]
          }
        ]
      }
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new).with(inbox: other_channel.inbox, params: wb_params)
      job.perform_now(wb_params)
    end
  end
end
