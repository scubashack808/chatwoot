require 'rails_helper'

RSpec.describe Captain::Llm::UpdateEmbeddingJob, type: :job do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:vector_a) { [1.0] + Array.new(1535, 0.0) }
  let(:vector_b) { [0.0, 1.0] + Array.new(1534, 0.0) }
  let(:embedding_service) { instance_double(Captain::Llm::EmbeddingService) }

  before do
    clear_enqueued_jobs
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(embedding_service)
    allow(embedding_service).to receive(:get_embedding).with(content_a).and_return(vector_a)
    allow(embedding_service).to receive(:get_embedding).with(content_b).and_return(vector_b)
  end

  after { clear_enqueued_jobs }

  shared_examples 'fresh embedding persistence' do
    it 'keeps the newer vector when serialized jobs finish B then A' do
      record.save!
      older = enqueued_jobs.find { |job| job[:job] == described_class }
      expect(older).to be_present
      clear_enqueued_jobs
      record.update!(new_attributes)
      newer = enqueued_jobs.find { |job| job[:job] == described_class }
      expect(newer).to be_present
      clear_enqueued_jobs

      described_class.deserialize(newer).perform_now
      expect(record.reload.embedding.to_a).to eq(vector_b)
      described_class.deserialize(older).perform_now

      expect(record.reload).to have_attributes(new_attributes)
      expect(record.embedding.to_a).to eq(vector_b)
      expect(enqueued_jobs.select { |job| job[:job] == described_class }).to be_empty
    end

    it 'persists both vectors in normal A then B order' do
      record.save!
      older = enqueued_jobs.find { |job| job[:job] == described_class }
      described_class.deserialize(older).perform_now
      expect(record.reload.embedding.to_a).to eq(vector_a)
      clear_enqueued_jobs

      record.update!(new_attributes)
      newer = enqueued_jobs.find { |job| job[:job] == described_class }
      described_class.deserialize(newer).perform_now

      expect(record.reload).to have_attributes(new_attributes)
      expect(record.embedding.to_a).to eq(vector_b)
    end

    it 'rejects A when an edit and B embedding complete during its request' do
      record.save!
      older = enqueued_jobs.find { |job| job[:job] == described_class }
      allow(embedding_service).to receive(:get_embedding).with(content_a) do
        clear_enqueued_jobs
        record.class.find(record.id).update!(new_attributes)
        newer = enqueued_jobs.find { |job| job[:job] == described_class }
        described_class.deserialize(newer).perform_now
        vector_a
      end

      described_class.deserialize(older).perform_now

      expect(record.reload).to have_attributes(new_attributes)
      expect(record.embedding.to_a).to eq(vector_b)
    end

    it 'does not save A if an edit occurs during its request and B is still queued' do
      record.save!
      older = enqueued_jobs.find { |job| job[:job] == described_class }
      allow(embedding_service).to receive(:get_embedding).with(content_a) do
        record.class.find(record.id).update!(new_attributes)
        vector_a
      end

      described_class.deserialize(older).perform_now

      expect(record.reload).to have_attributes(new_attributes)
      expect(record.embedding).to be_nil
    end

    it 'does not enqueue another job for an embedding-only update' do
      record.save!
      clear_enqueued_jobs

      expect { record.update!(embedding: vector_a) }.not_to have_enqueued_job(described_class)
    end
  end

  context 'with an assistant response' do
    let(:record) { assistant.responses.build(question: 'Question A', answer: 'Answer A') }
    let(:content_a) { 'Question A: Answer A' }
    let(:content_b) { 'Question B: Answer B' }
    let(:new_attributes) { { question: 'Question B', answer: 'Answer B' } }

    it_behaves_like 'fresh embedding persistence'
  end

  context 'with a FAQ suggestion' do
    let(:record) { Captain::FaqSuggestion.new(assistant: assistant, question: 'Question A', answer: 'Answer A') }
    let(:content_a) { 'Question A: Answer A' }
    let(:content_b) { 'Question B: Answer B' }
    let(:new_attributes) { { question: 'Question B', answer: 'Answer B' } }

    it_behaves_like 'fresh embedding persistence'

    it 'does not enqueue when a new suggestion already has an embedding' do
      record.embedding = vector_a

      expect { record.save! }.not_to have_enqueued_job(described_class)
    end

    it 'does not enqueue for a dismissed suggestion' do
      record.status = :dismissed

      expect { record.save! }.not_to have_enqueued_job(described_class)
      expect { record.update!(new_attributes) }.not_to have_enqueued_job(described_class)
    end
  end

  context 'with an article embedding' do
    let(:article) { create(:article, portal: create(:portal, account: account)) }
    let(:record) { ArticleEmbedding.new(article: article, term: content_a) }
    let(:content_a) { 'Term A' }
    let(:content_b) { 'Term B' }
    let(:new_attributes) { { term: content_b } }

    it_behaves_like 'fresh embedding persistence'
  end
end
