import { describe, it, beforeEach, afterEach, expect, vi } from 'vitest';
import ActionCableConnector from '../actionCable';
import { actions } from '../../store/modules/conversation/actions';
import { mutations } from '../../store/modules/conversation/mutations';
import { API } from '../axios';

vi.mock('../axios', () => ({ API: { get: vi.fn() } }));

vi.mock('@rails/actioncable', () => ({
  createConsumer: () => ({
    subscriptions: { create: () => ({}) },
    disconnect: vi.fn(),
  }),
}));

describe('Widget ActionCableConnector', () => {
  let app;
  let mockDispatch;
  let connector;

  beforeEach(() => {
    vi.useFakeTimers();
    mockDispatch = vi.fn();
    app = {
      $store: {
        dispatch: mockDispatch,
        getters: {
          getCurrentAccountId: 1,
          getCurrentUserID: 1,
        },
      },
    };
    connector = new ActionCableConnector(app, 'test-token');
    mockDispatch.mockClear();
  });

  afterEach(() => {
    vi.clearAllMocks();
    vi.useRealTimers();
  });

  it('awaits actual paginated recovery while refreshing attributes independently', async () => {
    vi.useRealTimers();
    const state = {
      conversations: { 1: { id: 1 } },
      lastMessageId: null,
      meta: {},
      uiFlags: { allMessagesLoaded: false },
    };
    const context = {
      state,
      commit: (name, payload) =>
        mutations[name.replace('conversation/', '')](state, payload),
    };
    mockDispatch.mockImplementation(name => {
      if (name === 'conversation/setLastMessageId')
        return actions.setLastMessageId(context);
      if (name === 'conversation/syncLatestMessages')
        return actions.syncLatestMessages(context);
      return Promise.resolve();
    });
    connector.onDisconnected();
    const firstPage = Array.from({ length: 100 }, (_, index) => ({
      id: index + 2,
      created_at: index + 2,
    }));
    firstPage.forEach(message =>
      mutations.pushMessageToConversation(state, message)
    );
    let resolvePage;
    API.get.mockResolvedValueOnce({ data: { payload: firstPage, meta: {} } });
    API.get.mockImplementationOnce(
      () =>
        new Promise(resolve => {
          resolvePage = resolve;
        })
    );
    const recovery = connector.onReconnect();
    expect(recovery).toBeInstanceOf(Promise);
    expect(mockDispatch).toHaveBeenCalledWith(
      'conversationAttributes/getAttributes'
    );
    await vi.waitFor(() => expect(API.get).toHaveBeenCalledTimes(2));
    expect(state.lastMessageId).toBe(1);
    mutations.pushMessageToConversation(state, { id: 500, created_at: 500 });
    resolvePage({
      data: { payload: [{ id: 102, created_at: 102 }], meta: {} },
    });
    expect(await recovery).toBe(true);
    expect(state.lastMessageId).toBeNull();
    expect(Object.keys(state.conversations)).toHaveLength(103);
    expect(state.conversations[102]).toBeDefined();
    expect(state.conversations[500]).toBeDefined();
    expect(API.get.mock.calls.map(([, { params }]) => params.after)).toEqual([
      1, 101,
    ]);
  });

  it('returns failed catch-up without blocking the attributes refresh', async () => {
    mockDispatch.mockImplementation(name =>
      Promise.resolve(name !== 'conversation/syncLatestMessages')
    );
    expect(await connector.onReconnect()).toBe(false);
    expect(mockDispatch).toHaveBeenCalledWith(
      'conversationAttributes/getAttributes'
    );
  });

  it('registers the conversation.status_changed event handler', () => {
    expect(connector.events['conversation.status_changed']).toBe(
      connector.onStatusChange
    );
  });

  it('re-fetches conversation attributes on reconnect so a status change missed while disconnected is reflected', () => {
    connector.onReconnect();

    expect(mockDispatch).toHaveBeenCalledWith(
      'conversation/syncLatestMessages'
    );
    expect(mockDispatch).toHaveBeenCalledWith(
      'conversationAttributes/getAttributes'
    );
  });
});
