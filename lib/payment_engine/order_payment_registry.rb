class PaymentEngine
  class OrderPaymentRegistry
    def initialize(repository)
      @repository = repository
    end

    def reserve(request)
      @repository.transaction do |repository|
        order_payment = repository.find_order_payment(request.order_payment_key)

        unless order_payment
          repository.save_order_payment(
            OrderPayment.new(
              order_payment_key: request.order_payment_key,
              fingerprint: request.fingerprint
            )
          )
          next OrderPayment::ReservationDecision.new(status: :reserved, result: nil)
        end

        reservation = order_payment.reserve(request.fingerprint)
        repository.save_order_payment(order_payment) if reservation.reserved?
        reservation
      end
    end

    def record_result(order_payment_key, provider_result)
      @repository.transaction do |repository|
        order_payment = repository.find_order_payment(order_payment_key)
        raise KeyError, "unknown order payment: #{order_payment_key.inspect}" unless order_payment

        order_payment.record_result(provider_result)
        resolve_provider_reference_collision(repository, order_payment, provider_result)
        repository.save_order_payment(order_payment)
        order_payment.result
      end
    end

    private

    def resolve_provider_reference_collision(repository, order_payment, provider_result)
      colliding_owner = find_colliding_owner(repository, order_payment, provider_result)
      return unless colliding_owner

      mark_both_as_duplicate(repository, order_payment, colliding_owner)
    end

    def find_colliding_owner(repository, order_payment, provider_result)
      provider_reference = provider_result.provider_reference
      return nil unless provider_reference

      owner_key = repository.claim_provider_reference(provider_reference, order_payment.order_payment_key)
      return nil if owner_key == order_payment.order_payment_key

      repository.find_order_payment(owner_key)
    end

    def mark_both_as_duplicate(repository, order_payment, owner_order_payment)
      order_payment.mark_unknown_due_to_duplicate_provider_reference!
      owner_order_payment.mark_unknown_due_to_duplicate_provider_reference!
      repository.save_order_payment(owner_order_payment)
    end
  end
end
