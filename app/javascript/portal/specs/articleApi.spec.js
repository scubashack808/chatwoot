import { beforeEach, describe, expect, it, vi } from 'vitest';
import axios from 'axios';
import ArticlesAPI from '../api/article';

vi.mock('axios', () => ({ default: { get: vi.fn() } }));

describe('ArticlesAPI.searchArticles', () => {
  beforeEach(() => {
    axios.get.mockReset();
  });

  it.each([
    'refund & cancellation',
    'section #2',
    'C++ setup',
    'refund policy',
  ])('sends %s as the literal query', query => {
    ArticlesAPI.searchArticles('help', 'en', query);

    expect(axios.get).toHaveBeenCalledOnce();
    const url = new URL(
      axios.get.mock.calls[0][0],
      'https://help.example.test'
    );
    expect(url.pathname).toBe('/hc/help/en/articles.json');
    expect(url.hash).toBe('');
    expect([...url.searchParams.keys()]).toEqual(['query']);
    expect(url.searchParams.get('query')).toBe(query);
  });
});
