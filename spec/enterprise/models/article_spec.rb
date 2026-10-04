require 'rails_helper'

RSpec.describe Article do
  describe '.vector_search' do
    let(:account) { create(:account) }
    let(:portal) { create(:portal, account: account, config: { allowed_locales: %w[en es] }) }
    let(:author) { create(:user, account: account) }
    let(:other_author) { create(:user, account: account) }
    let(:category) { create(:category, portal: portal, account: account, locale: 'en', slug: 'lagoon-en') }
    let(:vector) { [1.0] + Array.new(1535, 0.0) }
    let!(:uncategorized) { create(:article, account: account, portal: portal, author: author, category: nil, locale: 'en') }
    let!(:categorized) { create(:article, account: account, portal: portal, author: author, category: category) }
    let!(:uncategorized_es) { create(:article, account: account, portal: portal, author: author, category: nil, locale: 'es') }
    let!(:other_author_article) { create(:article, account: account, portal: portal, author: other_author, category: nil, locale: 'en') }
    let!(:draft) { create(:article, account: account, portal: portal, author: author, category: nil, locale: 'en', status: :draft) }
    let(:base_params) { { :account_id => account.id, 'query' => 'Lagoon', :limit => nil } }

    before do
      [uncategorized, categorized, uncategorized_es, other_author_article, draft].each do |article|
        ArticleEmbedding.create!(article: article, term: 'Lagoon', embedding: vector)
      end
      service = instance_double(Captain::Llm::EmbeddingService, get_embedding: vector)
      allow(Captain::Llm::EmbeddingService).to receive(:new).and_return(service)
    end

    it 'returns uncategorized and categorized articles in the requested locale' do
      results = described_class.vector_search(base_params.merge(locale: 'en'))

      expect(results.map(&:id)).to contain_exactly(uncategorized.id, categorized.id, other_author_article.id, draft.id)
    end

    it 'excludes uncategorized articles in other locales' do
      results = described_class.vector_search(base_params.merge(locale: 'es'))

      expect(results.map(&:id)).to contain_exactly(uncategorized_es.id)
    end

    it 'keeps the category filter strict' do
      results = described_class.vector_search(base_params.merge(locale: 'en', category_slug: category.slug))

      expect(results.map(&:id)).to contain_exactly(categorized.id)
    end

    it 'applies author and status filters' do
      expect(described_class.vector_search(base_params.merge(locale: 'en', author_id: other_author.id)).map(&:id))
        .to contain_exactly(other_author_article.id)
      expect(described_class.vector_search(base_params.merge(locale: 'en', status: 'draft')).map(&:id))
        .to contain_exactly(draft.id)
    end
  end
end
