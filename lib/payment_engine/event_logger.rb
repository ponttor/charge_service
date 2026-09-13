require 'json'

class PaymentEngine
  class EventLogger
    def initialize(logger)
      @logger = logger
    end

    def log(name, request, payment_result = nil, fields = {})
      context = request.respond_to?(:log_context) ? request.log_context : request
      context = {} unless context.is_a?(Hash)
      event = { event: name }.merge(context.slice(:merchant_id, :order_id, :amount, :currency, :correlation_id), fields)
      event[:status] = payment_result.status.to_s if payment_result
      event[:error_code] = payment_result.error_code if payment_result&.error_code
      @logger.info(JSON.generate(event.compact))
    rescue StandardError
      nil
    end
  end
end
