class PaymentEngine
  OrderPaymentKey = Data.define(:merchant_id, :order_id)

  class OrderPayment
    ReservationDecision = Data.define(:status, :result) do
      def reserved?
        status == :reserved
      end
    end

    attr_reader :order_payment_key, :fingerprint, :result

    def initialize(order_payment_key:, fingerprint:, result: nil)
      @order_payment_key = order_payment_key
      @fingerprint = fingerprint
      @result = result
    end

    def reserve(candidate_fingerprint)
      return ReservationDecision.new(status: :conflict, result: nil) if fingerprint != candidate_fingerprint
      return ReservationDecision.new(status: :in_progress, result: nil) if result.nil?
      return ReservationDecision.new(status: :completed, result: result) unless result.retryable_failure?

      @result = nil
      ReservationDecision.new(status: :reserved, result: nil)
    end

    def record_result(result)
      @result = result
    end

    def mark_unknown_due_to_duplicate_provider_reference!
      @result = result.with(status: :unknown, error_code: 'duplicate_system_order_ref')
    end
  end
end
