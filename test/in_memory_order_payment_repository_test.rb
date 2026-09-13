require_relative 'test_helper'

class InMemoryOrderPaymentRepositoryTest < Minitest::Test
  FIRST_KEY = PaymentEngine::OrderPaymentKey.new(merchant_id: 'merchant_42', order_id: 'order_1')
  SECOND_KEY = PaymentEngine::OrderPaymentKey.new(merchant_id: 'merchant_42', order_id: 'order_2')

  def test_rolls_back_aggregate_mutations_and_reference_claims
    repository = PaymentEngine::InMemoryOrderPaymentRepository.new
    original_result = payment_result(order_id: 'order_1', status: :retryable_failure)
    repository.transaction do |transaction|
      transaction.save_order_payment(
        PaymentEngine::OrderPayment.new(
          order_payment_key: FIRST_KEY,
          fingerprint: 'fingerprint',
          result: original_result
        )
      )
    end

    assert_raises(RuntimeError) do
      repository.transaction do |transaction|
        transaction.find_order_payment(FIRST_KEY).record_result(
          payment_result(order_id: 'order_1', status: :approved)
        )
        transaction.claim_provider_reference('provider_1', FIRST_KEY)
        raise 'rollback'
      end
    end

    restored_result = repository.transaction { |transaction| transaction.find_order_payment(FIRST_KEY).result }
    owner_order_payment_key = repository.transaction do |transaction|
      transaction.claim_provider_reference('provider_1', SECOND_KEY)
    end

    assert_equal original_result, restored_result
    assert_equal SECOND_KEY, owner_order_payment_key
  end

  private

  def payment_result(order_id:, status:)
    PaymentEngine::PaymentResult.new(
      status:,
      merchant_id: 'merchant_42',
      order_id:,
      amount: 1_500,
      currency: 'EUR',
      provider_reference: 'provider_1',
      redirect_url: nil,
      error_code: nil,
      error_message: nil
    )
  end
end
