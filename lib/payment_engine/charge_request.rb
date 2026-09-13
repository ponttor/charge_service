require 'json'
require 'openssl'
require 'securerandom'

class PaymentEngine
  OrderPaymentKey = Data.define(:merchant_id, :order_id)
  REQUEST_FIELDS = %i[merchant_id order_id amount currency card_token].freeze

  ChargeRequest = Data.define(:merchant_id, :order_id, :amount, :currency, :card_token, :fingerprint,
                              :correlation_id) do
    class << self
      def build(params, fingerprint_secret:)
        return [nil, { request: 'must be a hash' }] unless params.is_a?(Hash)

        attributes, key_errors = normalize_keys(params)
        return [nil, { keys: key_errors }] if key_errors.any?

        errors = validate_values(attributes)
        return [nil, errors] if errors.any?

        attributes = normalize_values(attributes)
        fingerprint = build_fingerprint(attributes, fingerprint_secret)

        [new(**attributes, fingerprint:, correlation_id: SecureRandom.uuid), {}]
      end

      private

      def validate_values(attributes)
        errors = {}
        errors[:merchant_id] = 'must be a non-empty string' if invalid_string?(attributes[:merchant_id])
        errors[:order_id] = 'must be a non-empty string' if invalid_string?(attributes[:order_id])
        errors[:amount] = 'must be a positive integer in minor units' if invalid_amount?(attributes[:amount])
        errors[:currency] = 'must be a three-letter code' if invalid_currency?(attributes[:currency])
        errors[:card_token] = 'must be a non-empty string' if invalid_string?(attributes[:card_token])
        errors
      end

      def normalize_values(attributes)
        attributes.merge(
          merchant_id: attributes[:merchant_id].strip,
          order_id: attributes[:order_id].strip,
          currency: attributes[:currency].upcase
        )
      end

      def build_fingerprint(attributes, secret)
        OpenSSL::HMAC.hexdigest(
          'SHA256',
          secret,
          JSON.generate([attributes[:amount], attributes[:currency], attributes[:card_token]])
        )
      end

      def invalid_amount?(amount)
        !amount.is_a?(Integer) || !amount.positive?
      end

      def invalid_currency?(currency)
        !currency.is_a?(String) || !currency.match?(/\A[A-Za-z]{3}\z/)
      end

      def invalid_string?(value)
        !value.is_a?(String) || value.strip.empty?
      end

      def normalize_keys(params)
        normalized = {}
        errors = []
        allowed = REQUEST_FIELDS.to_h { |member| [member.to_s, member] }

        params.each do |key, value|
          canonical = allowed[key.to_s] if key.is_a?(String) || key.is_a?(Symbol)
          if canonical.nil?
            errors << "unknown key #{key.inspect}"
          elsif normalized.key?(canonical)
            errors << "duplicate key #{canonical.inspect}"
          else
            normalized[canonical] = value
          end
        end

        missing = REQUEST_FIELDS - normalized.keys
        errors.concat(missing.map { |key| "missing key #{key.inspect}" })
        [normalized, errors]
      end
    end

    def order_payment_key
      OrderPaymentKey.new(merchant_id:, order_id:)
    end

    def provider_payload
      { amount:, currency:, card_token: }
    end

    def log_context
      { merchant_id:, order_id:, amount:, currency:, correlation_id: }
    end
  end
end
