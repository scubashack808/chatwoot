import endPoints from '../endPoints';

describe('#sendAttachment', () => {
  beforeEach(() => {
    vi.stubGlobal('WOOT_WIDGET', { $root: { $i18n: { locale: 'es' } } });
    vi.stubGlobal('referrerURL', '/synthetic-page');
    vi.spyOn(window, 'location', 'get').mockReturnValue({
      search: '?website_token=synthetic',
    });
    vi.spyOn(Date.prototype, 'toString').mockReturnValue('mock date');
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it('includes the runtime locale and preserves the file and pending metadata', () => {
    const file = new File(['synthetic'], 'synthetic.png', {
      type: 'image/png',
    });
    const { url, params } = endPoints.sendAttachment(
      { attachment: { file }, replyTo: 42 },
      { customAttributes: { plan: 'enterprise' }, labels: ['vip', 'customer'] }
    );

    expect(url).toBe(
      '/api/v1/widget/messages?website_token=synthetic&locale=es'
    );
    expect(params.get('message[attachments][]')).toMatchObject({
      name: 'synthetic.png',
      type: 'image/png',
      size: file.size,
    });
    expect([...params.entries()].slice(1)).toEqual([
      ['message[referer_url]', '/synthetic-page'],
      ['message[timestamp]', 'mock date'],
      ['message[reply_to]', '42'],
      ['custom_attributes[plan]', 'enterprise'],
      ['labels[]', 'vip'],
      ['labels[]', 'customer'],
    ]);
  });

  it('includes the runtime locale for upload IDs without optional metadata', () => {
    const { url, params } = endPoints.sendAttachment({
      attachment: { file: 'synthetic-upload-id' },
    });

    expect(url).toBe(
      '/api/v1/widget/messages?website_token=synthetic&locale=es'
    );
    expect([...params.entries()]).toEqual([
      ['message[attachments][]', 'synthetic-upload-id'],
      ['message[referer_url]', '/synthetic-page'],
      ['message[timestamp]', 'mock date'],
    ]);
  });

  it('preserves the explicit popout locale', () => {
    vi.spyOn(window, 'location', 'get').mockReturnValue({
      search: '?website_token=synthetic&locale=es',
    });
    const { url } = endPoints.sendAttachment({
      attachment: { file: 'synthetic-upload-id' },
    });
    const search = new URLSearchParams(url.split('?')[1]);

    expect(search.get('website_token')).toBe('synthetic');
    expect(search.getAll('locale').every(locale => locale === 'es')).toBe(true);
    expect(search.get('locale')).toBe('es');
  });

  it('keeps Spanish locale propagation for text and conversation creation', () => {
    expect(endPoints.sendMessage('hola').url).toBe(
      '/api/v1/widget/messages?website_token=synthetic&locale=es'
    );
    expect(endPoints.createConversation({ message: 'hola' }).url).toBe(
      '/api/v1/widget/conversations?website_token=synthetic&locale=es'
    );
  });
});

describe('#sendMessage', () => {
  it('returns correct payload', () => {
    const spy = vi.spyOn(global, 'Date').mockImplementation(() => ({
      toString: () => 'mock date',
    }));
    vi.spyOn(window, 'location', 'get').mockReturnValue({
      ...window.location,
      search: '?param=1',
    });

    window.WOOT_WIDGET = {
      $root: {
        $i18n: {
          locale: 'ar',
        },
      },
    };

    expect(endPoints.sendMessage('hello')).toEqual({
      url: `/api/v1/widget/messages?param=1&locale=ar`,
      params: {
        message: {
          content: 'hello',
          referer_url: '',
          timestamp: 'mock date',
        },
      },
    });
    spy.mockRestore();
  });
});

describe('#createConversation', () => {
  it('includes contact custom attributes in the payload', () => {
    const spy = vi.spyOn(global, 'Date').mockImplementation(() => ({
      toString: () => 'mock date',
    }));
    vi.spyOn(window, 'location', 'get').mockReturnValue({
      ...window.location,
      search: '?param=1',
    });

    window.WOOT_WIDGET = {
      $root: { $i18n: { locale: 'ar' } },
    };

    const result = endPoints.createConversation({
      fullName: 'John',
      emailAddress: 'john@example.com',
      phoneNumber: '+919745313456',
      message: 'hey',
      customAttributes: { order_id: '12345' },
      contactCustomAttributes: { cpf: '123.456.789-09' },
    });

    expect(result).toEqual({
      url: `/api/v1/widget/conversations?param=1&locale=ar`,
      params: {
        contact: {
          name: 'John',
          email: 'john@example.com',
          phone_number: '+919745313456',
          custom_attributes: { cpf: '123.456.789-09' },
        },
        message: {
          content: 'hey',
          timestamp: 'mock date',
          referer_url: '',
        },
        custom_attributes: { order_id: '12345' },
      },
    });
    spy.mockRestore();
  });
});

describe('#sendMessage with pending metadata', () => {
  it('includes custom_attributes and labels in payload', () => {
    const spy = vi.spyOn(global, 'Date').mockImplementation(() => ({
      toString: () => 'mock date',
    }));
    vi.spyOn(window, 'location', 'get').mockReturnValue({
      ...window.location,
      search: '?param=1',
    });

    window.WOOT_WIDGET = {
      $root: { $i18n: { locale: 'ar' } },
    };

    const result = endPoints.sendMessage('hello', null, {
      customAttributes: { plan: 'enterprise' },
      labels: ['vip'],
    });

    expect(result.params.custom_attributes).toEqual({ plan: 'enterprise' });
    expect(result.params.labels).toEqual(['vip']);
    spy.mockRestore();
  });

  it('does not include metadata keys when not provided', () => {
    const spy = vi.spyOn(global, 'Date').mockImplementation(() => ({
      toString: () => 'mock date',
    }));
    vi.spyOn(window, 'location', 'get').mockReturnValue({
      ...window.location,
      search: '?param=1',
    });

    window.WOOT_WIDGET = {
      $root: { $i18n: { locale: 'ar' } },
    };

    const result = endPoints.sendMessage('hello');
    expect(result.params.custom_attributes).toBeUndefined();
    expect(result.params.labels).toBeUndefined();
    spy.mockRestore();
  });
});

describe('#getConversation', () => {
  it('returns correct payload', () => {
    vi.spyOn(window, 'location', 'get').mockReturnValue({
      ...window.location,
      search: '',
    });
    expect(endPoints.getConversation({ before: 123 })).toEqual({
      url: `/api/v1/widget/messages`,
      params: {
        before: 123,
      },
    });
  });
});

describe('#triggerCampaign', () => {
  it('should returns correct payload', () => {
    const spy = vi.spyOn(global, 'Date').mockImplementation(() => ({
      toString: () => 'mock date',
    }));
    vi.spyOn(window, 'location', 'get').mockReturnValue({
      ...window.location,
      search: '',
    });
    const websiteToken = 'ADSDJ2323MSDSDFMMMASDM';
    const campaignId = 12;
    expect(
      endPoints.triggerCampaign({
        websiteToken,
        campaignId,
      })
    ).toEqual({
      url: `/api/v1/widget/events`,
      data: {
        name: 'campaign.triggered',
        event_info: {
          campaign_id: campaignId,
          referer: '',
          initiated_at: {
            timestamp: 'mock date',
          },
        },
      },
      params: {
        website_token: websiteToken,
      },
    });

    spy.mockRestore();
  });
});

describe('#getConversation', () => {
  it('should returns correct payload', () => {
    const spy = vi.spyOn(global, 'Date').mockImplementation(() => ({
      toString: () => 'mock date',
    }));
    vi.spyOn(window, 'location', 'get').mockReturnValue({
      ...window.location,
      search: '',
    });
    expect(
      endPoints.getConversation({
        after: 123,
      })
    ).toEqual({
      url: `/api/v1/widget/messages`,
      params: {
        after: 123,
        before: undefined,
      },
    });

    spy.mockRestore();
  });
});
