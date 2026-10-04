import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { useCallActions } from '../useCallSession';
import { useCallsStore } from 'dashboard/stores/calls';
import {
  handleVoiceCallCreated,
  handleVoiceCallUpdated,
  isLocalCall,
  markLocalCall,
} from 'dashboard/helper/voice';
import TwilioVoiceClient from 'dashboard/api/channel/voice/twilioVoiceClient';
import { useWhatsappCallSession } from '../useWhatsappCallSession';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/api/channel/voice/twilioVoiceClient', () => ({
  default: { endClientCall: vi.fn() },
}));
vi.mock('../useWhatsappCallSession', () => ({
  useWhatsappCallSession: vi.fn(),
  cleanupWhatsappSession: vi.fn(),
  sendWhatsappTerminateBeacon: vi.fn(),
}));

describe('useCallActions', () => {
  let wrapper;
  let actions;
  let callsStore;
  let message;
  let callSid;
  let deleteRequest;
  let whatsappSession;
  let sequence = 0;

  beforeEach(() => {
    sequence += 1;
    callSid = `CA-reject-retry-${sequence}`;
    message = {
      content_type: 'voice_call',
      message_type: 0,
      conversation_id: 10,
      inbox_id: 1,
      sender: { id: 20, name: 'Synthetic caller' },
      call: {
        id: 42,
        provider_call_id: callSid,
        provider: 'twilio',
        direction: 'incoming',
        status: 'ringing',
      },
    };
    deleteRequest = vi.fn().mockResolvedValue({ data: {} });
    vi.stubGlobal('axios', { delete: deleteRequest });
    whatsappSession = {
      rejectIncomingCall: vi.fn().mockResolvedValue(undefined),
      endActiveCall: vi.fn().mockResolvedValue(undefined),
    };
    useWhatsappCallSession.mockReturnValue(whatsappSession);
    const pinia = createPinia();
    setActivePinia(pinia);
    callsStore = useCallsStore();
    wrapper = mount(
      {
        setup() {
          actions = useCallActions();
          return () => null;
        },
      },
      { global: { plugins: [pinia] } }
    );
    handleVoiceCallCreated(message, 7, 'online');
  });

  afterEach(() => {
    wrapper.unmount();
    callsStore.$dispose();
    vi.unstubAllGlobals();
  });

  it('preserves the ringing entry and propagates a failed rejection for retry', async () => {
    const entry = callsStore.incomingCalls[0];
    const error = new Error('Rejected before provider mutation');
    deleteRequest.mockRejectedValueOnce(error);

    await expect(actions.rejectIncomingCall(callSid)).rejects.toBe(error);

    expect(deleteRequest).toHaveBeenCalledWith(
      expect.stringMatching(/\/inboxes\/1\/conference$/),
      { params: { conversation_id: 10, call_sid: callSid } }
    );
    expect(callsStore.incomingCalls).toEqual([entry]);
    expect(callsStore.incomingCalls[0]).toBe(entry);
    expect(TwilioVoiceClient.endClientCall).not.toHaveBeenCalled();

    await actions.rejectIncomingCall(callSid);
    expect(deleteRequest).toHaveBeenCalledTimes(2);
    expect(callsStore.incomingCalls).toEqual([]);
    handleVoiceCallCreated(message, 7, 'online');
    expect(callsStore.incomingCalls).toEqual([]);
  });

  it('allows hydration after failure without duplicating or suppressing the entry', async () => {
    deleteRequest.mockRejectedValueOnce(new Error('Reject failed'));
    await expect(actions.rejectIncomingCall(callSid)).rejects.toThrow(
      'Reject failed'
    );

    handleVoiceCallCreated(message, 7, 'online');
    expect(callsStore.incomingCalls).toHaveLength(1);
    // Evict only the fixture entry to exercise the real dismissed-SID guard.
    callsStore.dismissCall(callSid);
    handleVoiceCallCreated(message, 7, 'online');
    expect(callsStore.incomingCalls).toHaveLength(1);
  });

  it('suppresses stale hydration after successful rejection but allows a later ringing update', async () => {
    await actions.rejectIncomingCall(callSid);
    handleVoiceCallCreated(message, 7, 'online');
    expect(callsStore.incomingCalls).toEqual([]);

    handleVoiceCallUpdated(vi.fn(), message, 7, 'online');
    expect(callsStore.incomingCalls).toHaveLength(1);
  });

  it('does not surface hydration for an offline agent', () => {
    callsStore.dismissCall(callSid);
    handleVoiceCallCreated(message, 7, 'offline');
    expect(callsStore.incomingCalls).toEqual([]);
  });

  it('does not resurrect a terminal call when a pending rejection fails', async () => {
    let rejectRequest;
    deleteRequest.mockImplementationOnce(
      () =>
        new Promise((resolve, reject) => {
          rejectRequest = reject;
        })
    );
    const rejection = actions.rejectIncomingCall(callSid);
    const assertion = expect(rejection).rejects.toThrow('Reject failed');
    handleVoiceCallUpdated(
      vi.fn(),
      { ...message, call: { ...message.call, status: 'completed' } },
      7,
      'online'
    );
    rejectRequest(new Error('Reject failed'));
    await assertion;

    handleVoiceCallCreated(message, 7, 'online');
    expect(callsStore.incomingCalls).toEqual([]);
  });

  it.each([
    ['inbound', 'rejectIncomingCall'],
    ['outbound', 'endActiveCall'],
  ])(
    'uses WhatsApp %s rejection routing and only dismisses after success',
    async (callDirection, method) => {
      callsStore.addCall({
        callSid,
        provider: 'whatsapp',
        callId: 42,
        callDirection,
      });
      whatsappSession[method].mockRejectedValueOnce(
        new Error('Provider failed')
      );
      await expect(actions.rejectIncomingCall(callSid)).rejects.toThrow(
        'Provider failed'
      );
      expect(callsStore.incomingCalls).toHaveLength(1);

      await actions.rejectIncomingCall(callSid);
      expect(whatsappSession[method]).toHaveBeenNthCalledWith(2, 42);
      expect(deleteRequest).not.toHaveBeenCalled();
      expect(callsStore.incomingCalls).toEqual([]);
      handleVoiceCallCreated(message, 7, 'online');
      expect(callsStore.incomingCalls).toEqual([]);
    }
  );

  it('preserves local fallback when provider metadata is missing', async () => {
    callsStore.calls = [{ callSid, isActive: false }];
    await actions.rejectIncomingCall(callSid);
    expect(TwilioVoiceClient.endClientCall).toHaveBeenCalledOnce();
    expect(deleteRequest).not.toHaveBeenCalled();
    handleVoiceCallCreated(message, 7, 'online');
    expect(callsStore.incomingCalls).toEqual([]);
  });

  it('keeps explicit local dismissal suppressing stale hydration', () => {
    actions.dismissCall(callSid);
    handleVoiceCallCreated(message, 7, 'online');
    expect(callsStore.incomingCalls).toEqual([]);
    expect(deleteRequest).not.toHaveBeenCalled();
  });

  it('still tears down an active Twilio call when ending it fails', async () => {
    callsStore.setCallActive(callSid);
    markLocalCall(callSid);
    deleteRequest.mockRejectedValueOnce(new Error('Leave failed'));

    await expect(
      actions.endCall({ conversationId: 10, inboxId: 1, callSid })
    ).rejects.toThrow('Leave failed');
    expect(TwilioVoiceClient.endClientCall).toHaveBeenCalled();
    expect(callsStore.hasActiveCall).toBe(false);
    expect(isLocalCall(callSid)).toBe(false);
  });
});
