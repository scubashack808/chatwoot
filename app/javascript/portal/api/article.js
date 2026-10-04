import axios from 'axios';

class ArticlesAPI {
  constructor() {
    this.baseUrl = '';
  }

  searchArticles(portalSlug, locale, query) {
    const searchParams = new URLSearchParams({ query });
    return axios.get(
      `${this.baseUrl}/hc/${portalSlug}/${locale}/articles.json?${searchParams.toString()}`
    );
  }
}

export default new ArticlesAPI();
