class PaymentEngine
  class OrderPaymentRegistry
    def initialize(repository)
      @repository = repository
      @provider_reference_guard = ProviderReferenceGuard.new
    end

    def reserve(request)
      @repository.transaction do |repository|
        order_payment = repository.find_order_payment(request.order_payment_key)
        order_payment ? reserve_existing(repository, order_payment, request) : reserve_new(repository, request)
      end
    end

    def record_result(order_payment_key, provider_result)
      @repository.transaction do |repository|
        order_payment = repository.find_order_payment(order_payment_key)
        raise KeyError, "unknown order payment: #{order_payment_key.inspect}" unless order_payment

        order_payment.record_result(provider_result)
        @provider_reference_guard.resolve(repository, order_payment, provider_result)
        repository.save_order_payment(order_payment)
        order_payment.result
      end
    end

    private

    def reserve_new(repository, request)
      repository.save_order_payment(
        OrderPayment.new(order_payment_key: request.order_payment_key, fingerprint: request.fingerprint)
      )
      OrderPayment::ReservationDecision.new(status: :reserved, result: nil)
    end

    def reserve_existing(repository, order_payment, request)
      reservation = order_payment.reserve(request.fingerprint)
      repository.save_order_payment(order_payment) if reservation.reserved?
      reservation
    end
  end
end
