class PaymentEngine
  def initialize(
    provider_client:,
    logger:,
    fingerprint_secret:,
    repository: nil
  )
    @fingerprint_secret = fingerprint_secret
    @event_logger = EventLogger.new(logger)
    @order_payment_registry = OrderPaymentRegistry.new(repository || InMemoryOrderPaymentRepository.new)
    @provider_gateway = ProviderGateway.new(
      provider_client:,
      response_classifier: ProviderResponseClassifier.new,
      event_logger: @event_logger
    )
  end

  def call(request_params)
    request = build_request!(request_params)
    reservation = @order_payment_registry.reserve(request)
    return resolve_reservation(request, reservation) unless reservation.reserved?

    execute_reserved_charge(request)
  end

  private

  def build_request!(request_params)
    request, errors = ChargeRequest.build(request_params, fingerprint_secret: @fingerprint_secret)
    return request if errors.empty?

    log_event('charge_rejected', request_params, nil, exception: 'InvalidRequest', errors:)
    raise InvalidRequest, errors
  end

  def execute_reserved_charge(request)
    log_event('charge_received', request)
    provider_result = @provider_gateway.charge(request)
    stored_result = @order_payment_registry.record_result(request.order_payment_key, provider_result)
    log_event('charge_saved', request, stored_result)
    stored_result
  end

  def resolve_reservation(request, reservation)
    case reservation.status
    when :completed
      log_event('charge_reused', request, reservation.result)
      reservation.result
    when :in_progress
      in_progress_result = PaymentResult.for_request(request, status: :in_progress, error_code: 'request_in_progress')
      log_event('charge_reused', request, in_progress_result)
      in_progress_result
    when :conflict
      log_event('idempotency_conflict', request, nil, exception: 'IdempotencyConflict',
                                                      error_code: 'order_parameters_conflict')
      raise IdempotencyConflict, 'order parameters conflict'
    else
      raise "unknown reservation status: #{reservation.status.inspect}"
    end
  end

  def log_event(name, request, payment_result = nil, fields = {})
    @event_logger.log(name, request, payment_result, fields)
  end
end

require_relative 'payment_engine/errors'
require_relative 'payment_engine/payment_result'
require_relative 'payment_engine/order_payment'
require_relative 'payment_engine/event_logger'
require_relative 'payment_engine/in_memory_order_payment_repository'
require_relative 'payment_engine/order_payment_registry'
require_relative 'payment_engine/faraday_transport'
require_relative 'payment_engine/provider_client'
require_relative 'payment_engine/charge_request'
require_relative 'payment_engine/provider_response_classifier'
require_relative 'payment_engine/provider_gateway'
