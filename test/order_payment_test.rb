require_relative 'test_helper'

class OrderPaymentTest < Minitest::Test
  ORDER_PAYMENT_KEY = %w[merchant_42 ord_abc123].freeze
  FINGERPRINT = 'fingerprint'.freeze

  def test_reserves_a_new_attempt_after_a_retryable_failure
    order_payment = order_payment_with(result(status: :retryable_failure))

    assert_equal reservation(:reserved), order_payment.reserve(FINGERPRINT)
    assert_nil order_payment.result
  end

  def test_reuses_a_non_retryable_result
    approved = result(status: :approved)
    order_payment = order_payment_with(approved)

    assert_equal reservation(:completed, approved), order_payment.reserve(FINGERPRINT)
    assert_equal approved, order_payment.result
  end

  def test_reports_an_operation_without_a_result_as_in_progress
    order_payment = order_payment_with(nil)

    assert_equal reservation(:in_progress), order_payment.reserve(FINGERPRINT)
  end

  def test_rejects_a_different_fingerprint_without_interpreting_the_result
    order_payment = order_payment_with(result(status: :retryable_failure))

    assert_equal reservation(:conflict), order_payment.reserve('different')
    refute_nil order_payment.result
  end

  def test_marks_the_outcome_unknown_for_a_duplicate_provider_reference
    order_payment = order_payment_with(result(status: :approved))

    order_payment.mark_unknown_due_to_duplicate_provider_reference!

    assert_equal :unknown, order_payment.result.status
    assert_equal 'duplicate_system_order_ref', order_payment.result.error_code
  end

  private

  def reservation(status, result = nil)
    PaymentEngine::OrderPayment::ReservationDecision.new(status:, result:)
  end

  def order_payment_with(result)
    PaymentEngine::OrderPayment.new(
      order_payment_key: ORDER_PAYMENT_KEY,
      fingerprint: FINGERPRINT,
      result:
    )
  end

  def result(status:)
    PaymentEngine::PaymentResult.new(
      status:,
      merchant_id: ORDER_PAYMENT_KEY.first,
      order_id: ORDER_PAYMENT_KEY.last,
      amount: 1_500,
      currency: 'EUR',
      provider_reference: 'provider_1',
      redirect_url: nil,
      error_code: nil,
      error_message: nil
    )
  end
end
