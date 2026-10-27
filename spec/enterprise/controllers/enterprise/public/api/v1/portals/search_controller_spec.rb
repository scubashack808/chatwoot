require 'rails_helper'

RSpec.describe 'Public portal embedding search', type: :request do
  let(:account) { create(:account) }
  let(:author) { create(:user, :administrator, account: account) }
  let(:portal) { create(:portal, account: account, custom_domain: 'www.example.com', config: { allowed_locales: ['en'] }) }
  let(:category) { create(:category, portal: portal, account: account, locale: 'en') }
  let(:vector) { [1.0] + Array.new(1535, 0.0) }
  let!(:uncategorized) do
    create(:article, account: account, portal: portal, author: author, category: nil, locale: 'en', title: 'Lagoon uncategorized guide')
  end
  let!(:categorized) do
    create(:article, account: account, portal: portal, author: author, category: category, locale: 'en', title: 'Lagoon categorized guide')
  end
  let!(:draft) do
    create(:article, account: account, portal: portal, author: author, category: nil, locale: 'en', title: 'Lagoon draft guide', status: :draft)
  end

  before do
    account.enable_features!('help_center')
    [uncategorized, categorized, draft].each do |article|
      ArticleEmbedding.create!(article: article, term: 'Lagoon', embedding: vector)
    end
    service = instance_double(Captain::Llm::EmbeddingService, get_embedding: vector)
    allow(Captain::Llm::EmbeddingService).to receive(:new).and_return(service)
  end

  def article_links
    Nokogiri::HTML(response.body).css('a[href]').pluck('href').select { |href| href.include?('/articles/') }
  end

  context 'with help_center_embedding_search enabled' do
    before { account.enable_features!('help_center_embedding_search') }

    it 'returns published uncategorized and categorized articles from JSON search' do
      get "/hc/#{portal.slug}/en/articles.json", params: { query: 'Lagoon' }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch('payload').pluck('id')).to contain_exactly(uncategorized.id, categorized.id)
    end

    it 'links published uncategorized and categorized articles from the HTML search page' do
      get "/hc/#{portal.slug}/en/search", params: { query: 'Lagoon' }

      expect(response).to have_http_status(:ok)
      expect(article_links).to include(a_string_including(uncategorized.slug), a_string_including(categorized.slug))
      expect(article_links).not_to include(a_string_including(draft.slug))
    end
  end

  context 'with help_center_embedding_search disabled' do
    before { account.disable_features!('help_center_embedding_search') }

    it 'returns both published articles from ordinary JSON and HTML search' do
      get "/hc/#{portal.slug}/en/articles.json", params: { query: 'Lagoon' }
      expect(response.parsed_body.fetch('payload').pluck('id')).to contain_exactly(uncategorized.id, categorized.id)

      get "/hc/#{portal.slug}/en/search", params: { query: 'Lagoon' }
      expect(article_links).to include(a_string_including(uncategorized.slug), a_string_including(categorized.slug))
    end

    it 'shows the uncategorized article' do
      get "/hc/#{portal.slug}/articles/#{uncategorized.slug}"

      expect(response).to have_http_status(:ok)
    end
  end
end
