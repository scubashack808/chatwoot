require 'rails_helper'

RSpec.describe Captain::Llm::FaqGeneratorService do
  let(:content) { 'Sample content for FAQ generation' }
  let(:document) { create(:captain_document, content: content) }
  let(:service) { described_class.new(document: document) }
  let(:mock_chat) { instance_double(RubyLLM::Chat) }
  let(:sample_faqs) do
    [
      { 'question' => 'What is this service?', 'answer' => 'It generates FAQs.' },
      { 'question' => 'How does it work?', 'answer' => 'Using AI technology.' }
    ]
  end
  let(:mock_response) do
    instance_double(RubyLLM::Message, content: { faqs: sample_faqs }.to_json)
  end

  before do
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'test-key')
    allow(RubyLLM).to receive(:chat).and_return(mock_chat)
    allow(mock_chat).to receive(:with_temperature).and_return(mock_chat)
    allow(mock_chat).to receive(:with_params).and_return(mock_chat)
    allow(mock_chat).to receive(:with_instructions).and_return(mock_chat)
    allow(mock_chat).to receive(:ask).and_return(mock_response)
  end

  describe '#generate' do
    context 'when successful' do
      it 'uses the document FAQ generation feature model' do
        expect(RubyLLM).to receive(:chat).with(
          model: Llm::Models.default_model_for('document_faq_generation')
        ).and_return(mock_chat)

        described_class.new(document: document).generate
      end

      it 'resolves the feature model from the document account' do
        expect(Llm::FeatureRouter).to receive(:resolve).with(
          feature: 'document_faq_generation',
          account: document.account
        ).and_call_original

        described_class.new(document: document).generate
      end

      it 'returns parsed FAQs from the LLM response' do
        result = service.generate
        expect(result).to eq(sample_faqs)
      end

      it 'sends content to LLM with JSON response format' do
        expect(mock_chat).to receive(:with_params).with(response_format: { type: 'json_object' }).and_return(mock_chat)
        service.generate
      end

      it 'uses SystemPromptsService with the account language' do
        account_language = document.account.locale_english_name
        expect(Captain::Llm::SystemPromptsService).to receive(:faq_generator).with(account_language).at_least(:once).and_call_original
        service.generate
      end
    end

    context 'with different language' do
      before { allow(document.account).to receive(:locale_english_name).and_return('spanish') }

      it 'passes the correct language to SystemPromptsService' do
        expect(Captain::Llm::SystemPromptsService).to receive(:faq_generator).with('spanish').at_least(:once).and_call_original
        service.generate
      end
    end

    context 'when the model finds no FAQs' do
      let(:empty_response) { instance_double(RubyLLM::Message, content: '{"faqs": []}') }

      before { allow(mock_chat).to receive(:ask).and_return(empty_response) }

      it 'returns an empty array' do
        expect(service.generate).to eq([])
      end
    end

    context 'when LLM API fails' do
      before do
        allow(mock_chat).to receive(:ask).and_raise(RubyLLM::Error.new(nil, 'API Error'))
      end

      it 'raises a generation error' do
        expect { service.generate }.to raise_error do |error|
          expect(error.class.name).to eq('Captain::Llm::FaqGeneratorService::GenerationError')
          expect(error.message).to eq('LLM API Error: API Error')
        end
      end
    end

    {
      'response content is nil' => nil,
      'JSON parsing fails' => 'invalid json',
      'response is missing faqs key' => '{"data": []}',
      'faqs is not a list' => '{"faqs": "none"}',
      'a faq entry is not an object' => '{"faqs": ["question"]}'
    }.each do |description, content|
      context "when #{description}" do
        before { allow(mock_chat).to receive(:ask).and_return(instance_double(RubyLLM::Message, content: content)) }

        it 'raises a generation error' do
          expect { service.generate }.to(raise_error { |error| expect(error.class.name).to eq('Captain::Llm::FaqGeneratorService::GenerationError') })
        end
      end
    end
  end
end
