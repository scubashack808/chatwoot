import { mount } from '@vue/test-utils';
import TableOfContents from '../components/TableOfContents.vue';
import { getHeadingsfromTheArticle } from '../portalHelpers';

describe('getHeadingsfromTheArticle with TableOfContents', () => {
  let wrappers;

  beforeEach(() => {
    wrappers = [];
    vi.stubGlobal(
      'IntersectionObserver',
      class {
        observe() {}

        disconnect() {}
      }
    );
  });

  afterEach(() => {
    wrappers.forEach(wrapper => wrapper.unmount());
    document.body.innerHTML = '';
    vi.unstubAllGlobals();
  });

  const renderArticle = titles => {
    document.body.innerHTML = '<article id="cw-article-content"></article>';
    const article = document.getElementById('cw-article-content');
    const headings = titles.map(title => {
      const heading = document.createElement('h3');
      heading.textContent = title;
      // jsdom does not compute rendered innerText
      Object.defineProperty(heading, 'innerText', {
        value: title,
        configurable: true,
      });
      article.appendChild(heading);
      return heading;
    });
    const rows = getHeadingsfromTheArticle();
    const toc = mount(TableOfContents, { props: { rows } });
    wrappers.push(toc);
    const targets = toc
      .findAll('a')
      .map(link => document.getElementById(link.attributes('href').slice(1)));
    return { rows, headings, targets };
  };

  it('keeps ordinary slugs and correct targets for unique headings', () => {
    const { rows, headings, targets } = renderArticle([
      'Setup',
      'Requirements',
      'Usage',
    ]);

    expect(rows.map(row => row.slug)).toEqual([
      'setup',
      'requirements',
      'usage',
    ]);
    targets.forEach((target, index) => expect(target).toBe(headings[index]));
  });

  it.each([
    ['Requirements', 'Requirements'],
    ['Requirements!', 'requirements'],
  ])(
    'gives repeated or colliding headings their own target: %s / %s',
    (first, second) => {
      const { headings, targets } = renderArticle([first, second]);

      expect(headings.map(heading => heading.id)).toEqual([
        'requirements',
        'requirements-2',
      ]);
      expect(targets[0]).toBe(headings[0]);
      expect(targets[1]).toBe(headings[1]);
    }
  );

  it('points each heading permalink at its own heading', () => {
    const { headings } = renderArticle(['Requirements', 'Requirements']);

    headings.forEach(heading => {
      expect(heading.querySelector('a.permalink').getAttribute('href')).toBe(
        `#${heading.id}`
      );
    });
  });

  it('starts numbering fresh for each article initialization', () => {
    expect(renderArticle(['Requirements']).rows[0].slug).toBe('requirements');
    expect(renderArticle(['Requirements']).rows[0].slug).toBe('requirements');
  });
});
