require_relative 'test_helper'

class ProviderGatewayTest < Minitest::Test
  def test_does_not_retry_when_classification_raises_a_before_send_error
    provider_calls = 0
    provider_client = Object.new
    provider_client.define_singleton_method(:charge) do |**_payload|
      provider_calls += 1
      PaymentEngine::ProviderClient::ParsedResponse.new(
        status: 200,
        body: {},
        response_bytes: 2,
        response_sha256: 'response-sha256'
      )
    end
    response_classifier = Object.new
    response_classifier.define_singleton_method(:call) do |_response, _request|
      raise PaymentEngine::BeforeSendError, 'classifier failed'
    end
    log_sink = LogSink.new

    result = build_gateway(provider_client:, response_classifier:, log_sink:).charge(request)
    classified_event = log_sink.events.find { |event| event[:event] == 'provider_response_classified' }

    assert_equal :unknown, result.status
    assert_equal 'unexpected_provider_error', result.error_code
    assert_equal 1, provider_calls
    assert_equal 'PaymentEngine::BeforeSendError', classified_event[:error_class]
    assert_equal 200, classified_event[:http_status]
  end

  def test_logs_upcoming_attempt_numbers_and_waits_only_before_attempts_two_and_three
    provider_client = Object.new
    provider_client.define_singleton_method(:charge) do |**_payload|
      raise PaymentEngine::BeforeSendError, 'not sent'
    end
    log_sink = LogSink.new
    gateway = build_gateway(
      provider_client:,
      response_classifier: Object.new,
      log_sink:
    )
    delays = []
    gateway.define_singleton_method(:rand) { 0.5 }
    gateway.define_singleton_method(:sleep) { |delay| delays << delay }

    result = gateway.charge(request)
    retry_events = log_sink.events.select { |event| event[:event] == 'provider_retry_scheduled' }

    assert_equal :retryable_failure, result.status
    assert_equal([2, 3], retry_events.map { |event| event[:attempt] })
    assert_equal([150.0, 300.0], retry_events.map { |event| event[:delay_ms] })
    assert_equal 2, delays.size
    assert_in_delta 0.15, delays[0]
    assert_in_delta 0.3, delays[1]
  end

  private

  def build_gateway(provider_client:, response_classifier:, log_sink: LogSink.new)
    PaymentEngine::ProviderGateway.new(
      provider_client:,
      response_classifier:,
      event_logger: PaymentEngine::EventLogger.new(log_sink)
    )
  end

  def request
    request, errors = PaymentEngine::ChargeRequest.build(
      {
        merchant_id: 'merchant_42',
        order_id: 'ord_abc123',
        amount: 1_500,
        currency: 'EUR',
        card_token: 'tok_visa_4242'
      },
      fingerprint_secret: 'fingerprint-secret'
    )
    raise errors.inspect unless errors.empty?

    request
  end
end
