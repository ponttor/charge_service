class PaymentEngine
  class InMemoryOrderPaymentRepository
    def initialize
      @order_payments = {}
      @provider_reference_owners = {}
      @mutex = Mutex.new
    end

    def transaction(&)
      @mutex.synchronize do
        order_payments_before_transaction = @order_payments.transform_values do |order_payment|
          snapshot_order_payment(order_payment)
        end
        reference_owners_before_transaction = @provider_reference_owners.dup
        committed = false

        begin
          result = yield(self)
          committed = true
          result
        ensure
          unless committed
            @order_payments = order_payments_before_transaction
            @provider_reference_owners = reference_owners_before_transaction
          end
        end
      end
    end

    def find_order_payment(order_payment_key)
      @order_payments[order_payment_key]
    end

    def save_order_payment(order_payment)
      @order_payments[order_payment.order_payment_key] = order_payment
    end

    def claim_provider_reference(provider_reference, order_payment_key)
      @provider_reference_owners.fetch(provider_reference) do
        @provider_reference_owners[provider_reference] = order_payment_key
      end
    end

    private

    def snapshot_order_payment(order_payment)
      OrderPayment.new(
        order_payment_key: order_payment.order_payment_key,
        fingerprint: order_payment.fingerprint,
        result: order_payment.result
      )
    end
  end
end
