require 'uri'

class PaymentEngine
  class ProviderResponseClassifier
    Classification = Data.define(:status, :provider_reference, :redirect_url, :error_code)
    PROVIDER_FIELDS = %i[status system_order_ref amount currency threeds_url reason].freeze
    SERVER_ERROR_HTTP_STATUSES = (500..599)
    AUTHENTICATION_ERROR_HTTP_STATUSES = [401, 403].freeze
    RECOGNIZED_HTTP_STATUSES = [200, 422].freeze

    def call(response, request)
      http_error_classification = classify_http_status_error(response)
      return http_error_classification if http_error_classification

      body = normalize_body(response.body)
      return classification(:unknown, error_code: malformed_body_code(response.body)) if body.nil?

      case response.status
      when 422 then classify_http_422_response(body)
      when 200 then classify_http_200_response(body, request)
      end
    end

    private

    def classify_http_status_error(response)
      if SERVER_ERROR_HTTP_STATUSES.cover?(response.status)
        return classification(:unknown,
                              error_code: 'provider_server_error')
      end

      if AUTHENTICATION_ERROR_HTTP_STATUSES.include?(response.status)
        return classification(:unknown, error_code: 'provider_authentication_error')
      end

      unless RECOGNIZED_HTTP_STATUSES.include?(response.status)
        return classification(:unknown, error_code: 'unexpected_http_status')
      end

      nil
    end

    def malformed_body_code(raw_body)
      raw_body.to_s.empty? ? 'empty_response' : 'malformed_response'
    end

    def classify_http_422_response(body)
      if body[:status] == 'error' && body[:reason] == 'card_declined'
        classification(:declined, error_code: 'card_declined')
      else
        classification(:unknown, error_code: 'unexpected_decline_reason')
      end
    end

    def classify_http_200_response(body, request)
      provider_status = body[:status]

      unless %w[approved threeds_required].include?(provider_status)
        return classification(:unknown, error_code: 'unexpected_provider_status')
      end
      unless non_empty_string?(body[:system_order_ref])
        return classification(:unknown,
                              error_code: 'incomplete_response')
      end
      return classification(:unknown, error_code: 'amount_mismatch') unless body[:amount] == request.amount
      return classification(:unknown, error_code: 'currency_mismatch') unless body[:currency] == request.currency

      if provider_status == 'threeds_required' && !valid_https_url?(body[:threeds_url])
        return classification(:unknown, error_code: 'invalid_redirect_url')
      end

      classification(
        provider_status == 'threeds_required' ? :requires_action : :approved,
        provider_reference: body[:system_order_ref],
        redirect_url: body[:threeds_url]
      )
    end

    def classification(status, provider_reference: nil, redirect_url: nil, error_code: nil)
      Classification.new(status:, provider_reference:, redirect_url:, error_code:)
    end

    def normalize_body(body)
      return unless body.is_a?(Hash)

      PROVIDER_FIELDS.to_h do |field|
        value = body.key?(field) ? body[field] : body[field.to_s]
        [field, value]
      end
    end

    def valid_https_url?(value)
      uri = URI.parse(value.to_s)
      uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty? && uri.userinfo.nil?
    rescue URI::InvalidURIError
      false
    end

    def non_empty_string?(value)
      value.is_a?(String) && !value.empty?
    end
  end
end
