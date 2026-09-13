class PaymentEngine
  PaymentResult = Data.define(
    :status,
    :merchant_id,
    :order_id,
    :amount,
    :currency,
    :provider_reference,
    :redirect_url,
    :error_code,
    :error_message
  ) do
    alias_method :system_order_ref, :provider_reference
    alias_method :threeds_url, :redirect_url
    alias_method :reason, :error_code

    def retryable_failure?
      status == :retryable_failure
    end

    def self.for_request(request, status:, provider_reference: nil, redirect_url: nil, error_code: nil,
                         error_message: nil)
      new(
        status:,
        merchant_id: request.merchant_id,
        order_id: request.order_id,
        amount: request.amount,
        currency: request.currency,
        provider_reference:,
        redirect_url:,
        error_code:,
        error_message:
      )
    end
  end
end
