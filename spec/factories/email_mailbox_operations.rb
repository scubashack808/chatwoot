FactoryBot.define do
  factory :email_mailbox_operation do
    account
    inbox { association :inbox, account: account }
    conversation { association :conversation, account: account, inbox: inbox }
    user { association :user, account: account }
    action { :archive }
    idempotency_key { SecureRandom.uuid }
  end
end
