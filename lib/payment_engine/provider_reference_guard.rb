class PaymentEngine
  class ProviderReferenceGuard
    def resolve(repository, order_payment, provider_result)
      colliding_owner = find_colliding_owner(repository, order_payment, provider_result)
      return unless colliding_owner

      mark_both_as_duplicate(repository, order_payment, colliding_owner)
    end

    private

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
