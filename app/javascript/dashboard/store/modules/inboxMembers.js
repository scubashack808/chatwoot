import InboxMembersAPI from '../../api/inboxMembers';

export const actions = {
  get(_, { inboxId }) {
    return InboxMembersAPI.show(inboxId);
  },
  async create({ dispatch }, { inboxId, agentList }) {
    const response = await InboxMembersAPI.update({ inboxId, agentList });
    await dispatch('inboxes/get', { cache: false }, { root: true });
    return response;
  },
};

export default {
  namespaced: true,
  actions,
};
