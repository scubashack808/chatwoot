class Captain::Documents::ResponseBuilderJob < ApplicationJob
  queue_as :low

  # Provider outages and malformed model output are usually transient. The exhaustion
  # block absorbs the final error so it is reported once; the document keeps its previous
  # answers and a failed faq_generation status, and can be retried by re-enqueuing this job.
  retry_on Captain::Llm::FaqGeneratorService::GenerationError, wait: 5.seconds, attempts: 3 do |job, error|
    document = job.arguments.first
    ChatwootExceptionTracker.new(error, account: document.account).capture_exception
    Rails.logger.error("[Captain::Documents::ResponseBuilderJob] FAQ generation retries exhausted for document #{document.id} " \
                       "(account #{document.account_id}): #{error.message}")
  end

  def perform(document, options = {})
    faqs = generate_faqs(document, options)
    replace_responses(document, faqs)
  rescue Captain::Llm::FaqGeneratorService::GenerationError, ActiveRecord::RecordInvalid => e
    record_generation_outcome(document, 'failed', e.is_a?(ActiveRecord::RecordInvalid) ? 'response_invalid' : 'generation_failed')
    raise
  end

  private

  def generate_faqs(document, options)
    if should_use_pagination?(document)
      generate_paginated_faqs(document, options)
    else
      generate_standard_faqs(document)
    end
  end

  def generate_paginated_faqs(document, options)
    service = build_paginated_service(document, options)
    faqs = service.generate
    store_paginated_metadata(document, service)
    faqs
  end

  def generate_standard_faqs(document)
    Captain::Llm::FaqGeneratorService.new(document: document).generate
  end

  def build_paginated_service(document, options)
    Captain::Llm::PaginatedFaqGeneratorService.new(
      document,
      pages_per_chunk: options[:pages_per_chunk],
      max_pages: options[:max_pages],
      language: document.account.locale_english_name
    )
  end

  def store_paginated_metadata(document, service)
    document.update!(
      metadata: (document.metadata || {}).merge(
        'faq_generation' => {
          'method' => 'paginated',
          'pages_processed' => service.total_pages_processed,
          'iterations' => service.iterations_completed,
          'timestamp' => Time.current.iso8601
        }
      )
    )
  end

  def should_use_pagination?(document)
    # Auto-detect when to use pagination
    # For now, use pagination for PDFs with OpenAI file ID
    document.pdf_document? && document.openai_file_id.present?
  end

  # Swap answers only after generation succeeded, and all-or-nothing, so a failed
  # refresh never leaves the document with fewer answers than it had before.
  def replace_responses(document, faqs)
    ActiveRecord::Base.transaction do
      document.responses.where(edited: false).destroy_all
      faqs.each do |faq|
        # Created outside the association so a rolled-back row is not autosaved by the failure-metadata update.
        Captain::AssistantResponse.create!(
          question: faq['question'],
          answer: faq['answer'],
          assistant: document.assistant,
          documentable: document
        )
      end
      record_generation_outcome(document, 'succeeded', nil)
    end
  end

  def record_generation_outcome(document, status, error_code)
    metadata = document.metadata || {}
    generation = (metadata['faq_generation'] || {}).merge(
      'status' => status,
      'error_code' => error_code,
      'attempted_at' => Time.current.iso8601
    )
    document.update!(metadata: metadata.merge('faq_generation' => generation))
  end
end
