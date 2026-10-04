require 'rails_helper'

RSpec.describe Captain::Documents::ResponseBuilderJob, type: :job do
  let(:assistant) { create(:captain_assistant) }
  let(:document) { create(:captain_document, assistant: assistant) }
  let(:faq_generator) { instance_double(Captain::Llm::FaqGeneratorService) }
  let(:faqs) do
    [
      { 'question' => 'What is Ruby?', 'answer' => 'A programming language' },
      { 'question' => 'What is Rails?', 'answer' => 'A web framework' }
    ]
  end

  describe '#perform' do
    before do
      allow(Captain::Llm::FaqGeneratorService).to receive(:new).with(document: document).and_return(faq_generator)
      allow(faq_generator).to receive(:generate).and_return(faqs)
    end

    context 'when processing a document' do
      it 'deletes previous responses' do
        existing_response = create(:captain_assistant_response, documentable: document)

        described_class.new.perform(document)

        expect { existing_response.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'creates new responses for each FAQ' do
        expect do
          described_class.new.perform(document)
        end.to change(Captain::AssistantResponse, :count).by(2)

        responses = document.responses.reload
        expect(responses.count).to eq(2)

        first_response = responses.first
        expect(first_response.question).to eq('What is Ruby?')
        expect(first_response.answer).to eq('A programming language')
        expect(first_response.assistant).to eq(assistant)
        expect(first_response.documentable).to eq(document)
      end
    end

    context 'when FAQ generation fails' do
      let!(:unedited_response) { create(:captain_assistant_response, assistant: assistant, documentable: document) }
      let!(:edited_response) { create(:captain_assistant_response, assistant: assistant, documentable: document, edited: true) }

      before do
        allow(faq_generator).to receive(:generate).and_raise(Captain::Llm::FaqGeneratorService::GenerationError, 'LLM API Error: boom')
      end

      it 'keeps every existing answer, records the failure and schedules a retry' do
        described_class.perform_now(document)

        expect(document.responses.reload).to contain_exactly(unedited_response, edited_response)
        expect(document.reload.metadata['faq_generation']).to include('status' => 'failed', 'error_code' => 'generation_failed')
        expect(described_class).to have_been_enqueued.with(document)
      end

      it 'reports once and keeps the answers when retries are exhausted' do
        allow(ChatwootExceptionTracker).to receive(:new).and_call_original

        perform_enqueued_jobs(only: described_class) { described_class.perform_later(document) }

        expect(faq_generator).to have_received(:generate).exactly(3).times
        expect(ChatwootExceptionTracker).to have_received(:new).once
        expect(document.responses.reload).to contain_exactly(unedited_response, edited_response)
        expect(document.reload.metadata['faq_generation']['status']).to eq('failed')
      end
    end

    context 'when a generated FAQ cannot be saved' do
      let(:faqs) do
        [
          { 'question' => 'What is Ruby?', 'answer' => 'A programming language' },
          { 'question' => 'What is Rails?', 'answer' => '' }
        ]
      end

      it 'rolls back the whole replacement and records the failure' do
        existing_response = create(:captain_assistant_response, assistant: assistant, documentable: document)

        expect { described_class.perform_now(document) }.to raise_error(ActiveRecord::RecordInvalid)

        expect(document.responses.reload).to contain_exactly(existing_response)
        expect(document.reload.metadata['faq_generation']).to include('status' => 'failed', 'error_code' => 'response_invalid')
      end
    end

    context 'when the model finds no FAQs' do
      let(:faqs) { [] }

      it 'removes unedited answers, keeps edited ones and records success' do
        create(:captain_assistant_response, assistant: assistant, documentable: document)
        edited_response = create(:captain_assistant_response, assistant: assistant, documentable: document, edited: true)

        described_class.perform_now(document)

        expect(document.responses.reload).to contain_exactly(edited_response)
        expect(document.reload.metadata['faq_generation']).to include('status' => 'succeeded', 'error_code' => nil)
      end
    end

    it 'keeps unrelated metadata when recording the generation outcome' do
      document.update!(metadata: document.metadata.merge('content_fingerprint' => 'abc', 'faq_generation' => { 'method' => 'paginated' }))

      described_class.perform_now(document)

      metadata = document.reload.metadata
      expect(metadata['content_fingerprint']).to eq('abc')
      expect(metadata['faq_generation']).to include('method' => 'paginated', 'status' => 'succeeded')
    end

    context 'with different locales' do
      let(:spanish_account) { create(:account, locale: 'pt') }
      let(:spanish_assistant) { create(:captain_assistant, account: spanish_account) }
      let(:spanish_document) { create(:captain_document, assistant: spanish_assistant, account: spanish_account) }
      let(:spanish_faq_generator) { instance_double(Captain::Llm::FaqGeneratorService) }

      before do
        allow(Captain::Llm::FaqGeneratorService).to receive(:new).with(document: spanish_document).and_return(spanish_faq_generator)
        allow(spanish_faq_generator).to receive(:generate).and_return(faqs)
      end

      it 'passes the correct document to FAQ generator' do
        described_class.new.perform(spanish_document)

        expect(Captain::Llm::FaqGeneratorService).to have_received(:new).with(document: spanish_document)
      end
    end

    context 'when processing a PDF document' do
      let(:pdf_document) do
        doc = create(:captain_document, assistant: assistant)
        allow(doc).to receive(:pdf_document?).and_return(true)
        allow(doc).to receive(:openai_file_id).and_return('file-123')
        allow(doc).to receive(:update!).and_return(true)
        allow(doc).to receive(:metadata).and_return({})
        doc
      end
      let(:paginated_service) { instance_double(Captain::Llm::PaginatedFaqGeneratorService) }
      let(:pdf_faqs) do
        [{ 'question' => 'What is in the PDF?', 'answer' => 'Important content' }]
      end

      before do
        allow(Captain::Llm::PaginatedFaqGeneratorService).to receive(:new)
          .with(pdf_document, anything)
          .and_return(paginated_service)
        allow(paginated_service).to receive(:generate).and_return(pdf_faqs)
        allow(paginated_service).to receive(:total_pages_processed).and_return(10)
        allow(paginated_service).to receive(:iterations_completed).and_return(1)
      end

      it 'uses paginated FAQ generator for PDFs' do
        expect(Captain::Llm::PaginatedFaqGeneratorService).to receive(:new).with(pdf_document, anything)

        described_class.new.perform(pdf_document)
      end

      it 'stores pagination metadata' do
        expect(pdf_document).to receive(:update!).with(hash_including(metadata: hash_including('faq_generation')))

        described_class.new.perform(pdf_document)
      end
    end
  end

  describe 'refreshing a synced web document' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:document) { create(:captain_document, assistant: assistant, account: account, status: :available, content: 'Original instructions') }
    let!(:unedited_response) { create(:captain_assistant_response, assistant: assistant, documentable: document) }
    let!(:edited_response) { create(:captain_assistant_response, assistant: assistant, documentable: document, edited: true) }
    let(:chat) { instance_double(RubyLLM::Chat) }
    let(:fetch_result) do
      Captain::Documents::SinglePageFetcher::Result.new(success: true, title: document.name, content: 'Updated instructions')
    end

    before do
      create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'test-key')
      document.update!(content_fingerprint: Digest::SHA256.hexdigest('Original instructions'), sync_status: :synced)
      fetcher = instance_double(Captain::Documents::SinglePageFetcher, fetch: fetch_result)
      allow(Captain::Documents::SinglePageFetcher).to receive(:new).and_return(fetcher)
      allow(RubyLLM).to receive(:chat).and_return(chat)
      allow(chat).to receive_messages(with_temperature: chat, with_params: chat, with_instructions: chat)
      allow(chat).to receive(:ask).and_raise(RubyLLM::Error.new(nil, 'synthetic API failure'))
      clear_enqueued_jobs
    end

    it 'keeps existing answers and schedules a retry when the model fails after a content change' do
      Captain::Documents::SyncService.new(document).perform
      perform_enqueued_jobs(only: described_class)

      expect(chat).to have_received(:ask).at_least(:once)
      expect(document.responses.reload).to contain_exactly(unedited_response, edited_response)
      document.reload
      expect(document.content).to eq('Updated instructions')
      expect(document).to be_sync_synced
      expect(document.metadata['faq_generation']).to include('status' => 'failed', 'error_code' => 'generation_failed')
      expect(described_class).to have_been_enqueued.with(document)
    end

    it 'replaces unedited answers once the retry succeeds' do
      Captain::Documents::SyncService.new(document).perform
      perform_enqueued_jobs(only: described_class)
      allow(chat).to receive(:ask).and_return(
        instance_double(RubyLLM::Message, content: { faqs: [{ question: 'Replacement?', answer: 'Replacement answer' }] }.to_json)
      )

      perform_enqueued_jobs(only: described_class)

      expect(document.responses.reload.map(&:question)).to contain_exactly(edited_response.question, 'Replacement?')
      expect(document.reload.metadata['faq_generation']).to include('status' => 'succeeded', 'error_code' => nil)
    end
  end
end
