import actionQueryGenerator from '../actionQueryGenerator';

const testData = [
  {
    action_name: 'add_label',
    action_params: [{ id: 'testlabel', name: 'testlabel' }],
  },
  {
    action_name: 'assign_team',
    action_params: [
      {
        id: 1,
        name: 'sales team',
        description: 'This is our internal sales team',
        allow_auto_assign: true,
        account_id: 1,
        is_member: true,
      },
    ],
  },
];

const finalResult = [
  {
    action_name: 'add_label',
    action_params: ['testlabel'],
  },
  {
    action_name: 'assign_team',
    action_params: [1],
  },
];

describe('#actionQueryGenerator', () => {
  it.each(['open', 'resolved', 'pending', 'snoozed', 0, 1, 2, 3])(
    'preserves status ID %s from persisted arrays and selected options',
    id => {
      const option = { id, name: 'Status' };
      [[id], [option], option].forEach(params => {
        expect(
          actionQueryGenerator([
            { action_name: 'change_status', action_params: params },
          ])
        ).toEqual([{ action_name: 'change_status', action_params: [id] }]);
      });
    }
  );

  it('returns the correct format of filter query', () => {
    expect(actionQueryGenerator(testData)).toEqual(finalResult);
    expect(
      actionQueryGenerator(testData).every(i => Array.isArray(i.action_params))
    ).toBe(true);
  });
});
