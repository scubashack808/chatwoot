require 'rails_helper'

# Review finding P3-3. Mail::Header#[] returns a single Mail::Field for one occurrence and an
# Array of fields for two or more, so `&.value` raises NoMethodError on a repeated header. The
# raise lands inside message creation (MailboxSanitizer -> serialized_data -> headers_data), which
# means the customer's email is lost to a failed InboundEmail rather than degrading to a missing
# header. Two Postfix hops each stamping X-Original-To is exactly the forwarding topology this
# row's alias routing exists to serve.
RSpec.describe MailPresenter do
  def mail_with_original_to(*values)
    mail = Mail.new(from: 'customer@example.com', to: 'care@example.com', subject: 'Hello', body: 'Hi')
    values.each { |value| mail['X-Original-To'] = value }
    mail
  end

  describe '#headers_data' do
    it 'keeps the value when X-Original-To appears once' do
      presenter = described_class.new(mail_with_original_to('care@example.com'))

      expect(presenter.headers_data['x-original-to']).to eq('care@example.com')
    end

    it 'keeps the first value when X-Original-To appears twice' do
      presenter = described_class.new(mail_with_original_to('nonprofit@example.com', 'care@example.com'))

      expect(presenter.headers_data['x-original-to']).to eq('nonprofit@example.com')
    end

    it 'reports no headers at all when X-Original-To is absent' do
      presenter = described_class.new(mail_with_original_to)

      expect(presenter.headers_data).to be_nil
    end
  end

  describe '#serialized_data' do
    it 'does not raise on a doubled X-Original-To' do
      presenter = described_class.new(mail_with_original_to('nonprofit@example.com', 'care@example.com'))

      expect { presenter.serialized_data }.not_to raise_error
    end
  end
end
