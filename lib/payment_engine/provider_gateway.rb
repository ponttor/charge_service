class PaymentEngine
  class ProviderGateway
    MAX_ATTEMPTS = 3
    BASE_RETRY_DELAY = 0.1

    def initialize(provider_client:, response_classifier:, event_logger:)
      @provider_client = provider_client
      @response_classifier = response_classifier
      @event_logger = event_logger
    end

    def charge(request)
      attempt_number = 1

      begin
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        log_request_started(request, attempt_number)
        response = @provider_client.charge(**request.provider_payload)
        classify_response(request, response, started_at)
      rescue BeforeSendError => error
        log_before_send_error(request, error, started_at)

        if attempt_number < MAX_ATTEMPTS
          attempt_number += 1
          wait_before_retry(request, attempt_number)
          retry
        end

        retryable_failure_result(request)
      rescue AmbiguousTransportError => error
        transport_error_result(request, error, started_at, error_code: 'provider_outcome_unknown')
      rescue StandardError => error
        transport_error_result(request, error, started_at, error_code: 'unexpected_provider_error')
      end
    end

    private

    def log_request_started(request, attempt_number)
      @event_logger.log('provider_request_started', request, nil, attempt: attempt_number)
    end

    def classify_response(request, response, started_at)
      payment_result = build_payment_result(response, request)
      log_classified_response(request, response, payment_result, started_at)
      payment_result
    rescue StandardError => error
      response_processing_error_result(request, response, error, started_at)
    end

    def log_classified_response(request, response, payment_result, started_at)
      @event_logger.log(
        'provider_response_classified',
        request,
        payment_result,
        http_status: response.status,
        duration_ms: elapsed_ms(started_at),
        provider_reference: payment_result.provider_reference,
        response_bytes: response.response_bytes,
        response_sha256: response.response_sha256
      )
    end

    def log_before_send_error(request, error, started_at)
      @event_logger.log(
        'provider_transport_error',
        request,
        nil,
        error_class: error.class.name,
        error_code: 'failed_before_send',
        duration_ms: elapsed_ms(started_at)
      )
    end

    def wait_before_retry(request, next_attempt_number)
      delay = retry_delay(next_attempt_number)
      @event_logger.log(
        'provider_retry_scheduled',
        request,
        nil,
        attempt: next_attempt_number,
        delay_ms: (delay * 1_000).round(3)
      )
      sleep(delay)
    end

    def retry_delay(next_attempt_number)
      BASE_RETRY_DELAY * (2**(next_attempt_number - 2)) * (1.0 + rand)
    end

    def retryable_failure_result(request)
      PaymentResult.for_request(
        request,
        status: :retryable_failure,
        error_code: 'provider_unreachable_before_send'
      )
    end

    def response_processing_error_result(request, response, error, started_at)
      unknown_result(
        request,
        error_code: 'unexpected_provider_error',
        event: 'provider_response_classified',
        event_fields: {
          error_class: error.class.name,
          http_status: response.status,
          duration_ms: elapsed_ms(started_at),
          response_bytes: response.response_bytes,
          response_sha256: response.response_sha256
        }
      )
    end

    def transport_error_result(request, error, started_at, error_code:)
      unknown_result(
        request,
        error_code:,
        event: 'provider_transport_error',
        event_fields: {
          error_class: error.class.name,
          duration_ms: elapsed_ms(started_at)
        }
      )
    end

    def unknown_result(request, error_code:, event:, event_fields: {})
      payment_result = PaymentResult.for_request(request, status: :unknown, error_code:)
      @event_logger.log(event, request, payment_result, **event_fields)
      payment_result
    end

    def elapsed_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1_000).round(3)
    end

    def build_payment_result(response, request)
      classification = @response_classifier.call(response, request)
      PaymentResult.for_request(
        request,
        status: classification.status,
        provider_reference: classification.provider_reference,
        redirect_url: classification.redirect_url,
        error_code: classification.error_code
      )
    end
  end
end
