class Captain::Llm::FaqGeneratorService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  # Raised instead of returning [] so callers can tell a failed generation apart
  # from a model that legitimately found no FAQs, and keep existing answers.
  class GenerationError < StandardError; end

  def initialize(document:)
    super(feature: 'document_faq_generation', account: document.account)
    @document = document
    @content = document.content
    @language = document.account.locale_english_name
    @account_id = document.account_id
  end

  def generate
    response = instrument_llm_call(instrumentation_params) do
      chat
        .with_params(response_format: { type: 'json_object' })
        .with_instructions(system_prompt)
        .ask(@content)
    end

    parse_response(response.content)
  rescue RubyLLM::Error => e
    raise GenerationError, "LLM API Error: #{e.message}"
  end

  private

  attr_reader :content, :language

  def system_prompt
    Captain::Llm::SystemPromptsService.faq_generator(language)
  end

  def instrumentation_params
    {
      span_name: 'llm.captain.faq_generator',
      model: @model,
      temperature: @temperature,
      feature_name: 'faq_generator',
      account_id: @account_id,
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: @content }
      ],
      metadata: document_metadata
    }
  end

  def document_metadata
    @document&.to_llm_metadata || {}
  end

  def parse_response(content)
    raise GenerationError, 'FAQ generation response was empty' if content.nil?

    parsed = JSON.parse(sanitize_json_response(content))
    faqs = parsed['faqs'] if parsed.is_a?(Hash)
    raise GenerationError, 'FAQ generation response did not contain a faqs list' unless faqs.is_a?(Array) && faqs.all?(Hash)

    faqs
  rescue JSON::ParserError => e
    raise GenerationError, "Error in parsing GPT processed response: #{e.message}"
  end
end
