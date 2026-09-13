require_relative 'test_helper'

class PaymentEngineTest < Minitest::Test
  CHARGES_URL = 'https://api.paymentprovider.com/charges'.freeze

  class CopyingRepository
    attr_reader :saved_states

    def initialize(order_payment)
      @order_payments = { order_payment.order_payment_key => copy(order_payment) }
      @provider_reference_owners = {}
      @saved_states = []
    end

    def transaction
      yield self
    end

    def find_order_payment(order_payment_key)
      order_payment = @order_payments[order_payment_key]
      copy(order_payment) if order_payment
    end

    def save_order_payment(order_payment)
      @saved_states << order_payment.result&.status
      @order_payments[order_payment.order_payment_key] = copy(order_payment)
    end

    def claim_provider_reference(provider_reference, order_payment_key)
      @provider_reference_owners.fetch(provider_reference) do
        @provider_reference_owners[provider_reference] = order_payment_key
      end
    end

    private

    def copy(order_payment)
      PaymentEngine::OrderPayment.new(
        order_payment_key: order_payment.order_payment_key,
        fingerprint: order_payment.fingerprint,
        result: order_payment.result
      )
    end
  end

  def setup
    @provider_client = PaymentEngine::ProviderClient.new(token: 'provider-secret')
    @logger = Logger.new(StringIO.new)
    @engine = build_engine
  end

  def build_engine(**overrides)
    PaymentEngine.new(
      provider_client: @provider_client,
      logger: @logger,
      fingerprint_secret: 'fingerprint-secret', **overrides
    )
  end

  def valid_request
    {
      merchant_id: 'merchant_42',
      order_id: 'ord_abc123',
      amount: 1_500,
      currency: 'EUR',
      card_token: 'tok_visa_4242'
    }
  end

  def approved_response
    {
      status: 'approved',
      system_order_ref: 'provider_1',
      amount: 1_500,
      currency: 'EUR'
    }
  end

  def test_raises_invalid_request_for_a_non_hash_request_before_any_provider_call
    error = assert_raises(PaymentEngine::InvalidRequest) { @engine.call(nil) }
    assert_equal({ request: 'must be a hash' }, error.errors)

    assert_not_requested :post, CHARGES_URL
  end

  def test_raises_invalid_request_for_unknown_request_keys
    error = assert_raises(PaymentEngine::InvalidRequest) do
      @engine.call(valid_request.merge(note: 'not part of the contract'))
    end
    assert_includes error.errors.fetch(:keys), 'unknown key :note'

    assert_not_requested :post, CHARGES_URL
  end

  def test_raises_invalid_request_when_string_and_symbol_forms_duplicate_a_field
    request = valid_request.merge('amount' => 1_500)

    error = assert_raises(PaymentEngine::InvalidRequest) { @engine.call(request) }
    assert_includes error.errors.fetch(:keys), 'duplicate key :amount'

    assert_not_requested :post, CHARGES_URL
  end

  {
    'negative_amount' => [{ amount: -100 }, :amount, 'must be a positive integer in minor units'],
    'zero_amount' => [{ amount: 0 }, :amount, 'must be a positive integer in minor units'],
    'non_integer_amount' => [{ amount: 15.5 }, :amount, 'must be a positive integer in minor units'],
    'currency_of_wrong_length' => [{ currency: 'EURO' }, :currency, 'must be a three-letter code'],
    'currency_with_non_letter_characters' => [{ currency: '12E' }, :currency, 'must be a three-letter code'],
    'blank_merchant_id' => [{ merchant_id: '   ' }, :merchant_id, 'must be a non-empty string'],
    'blank_order_id' => [{ order_id: '' }, :order_id, 'must be a non-empty string'],
    'blank_card_token' => [{ card_token: '' }, :card_token, 'must be a non-empty string']
  }.each do |scenario, (overrides, field, message)|
    define_method("test_rejects_#{scenario}_before_any_provider_call") do
      error = assert_raises(PaymentEngine::InvalidRequest) do
        @engine.call(valid_request.merge(overrides))
      end

      assert_equal message, error.errors[field]
      assert_not_requested :post, CHARGES_URL
    end
  end

  def test_normalizes_string_keys_and_currency_before_an_approved_provider_request
    provider_request = stub_request(:post, CHARGES_URL)
                       .with(
                         headers: {
                           'Authorization' => 'Bearer provider-secret',
                           'Content-Type' => 'application/json'
                         },
                         body: { amount: 1_500, currency: 'EUR', card_token: 'tok_visa_4242' }.to_json
                       )
                       .to_return(
                         status: 200,
                         body: {
                           status: 'approved',
                           system_order_ref: 'provider_1',
                           amount: 1_500,
                           currency: 'EUR'
                         }.to_json
                       )

    result = @engine.call(
      'merchant_id' => 'merchant_42',
      'order_id' => 'ord_abc123',
      'amount' => 1_500,
      'currency' => 'eur',
      'card_token' => 'tok_visa_4242'
    )

    assert_equal(
      {
        status: :approved,
        merchant_id: 'merchant_42',
        order_id: 'ord_abc123',
        amount: 1_500,
        currency: 'EUR',
        provider_reference: 'provider_1'
      },
      result.to_h.slice(:status, :merchant_id, :order_id, :amount, :currency, :provider_reference)
    )
    assert_requested(provider_request, times: 1)
  end

  def test_retrying_an_approved_order_with_the_same_parameters_reuses_the_stored_result
    provider_request = stub_request(:post, CHARGES_URL)
                       .to_return(status: 200, body: approved_response.to_json)

    first_result = @engine.call(valid_request)
    second_result = @engine.call(valid_request)

    assert_equal :approved, second_result.status
    assert_equal first_result, second_result
    assert_requested(provider_request, times: 1)
  end

  def test_treats_an_undocumented_provider_processing_status_as_unknown
    stub_request(:post, CHARGES_URL)
      .to_return(
        status: 200,
        body: {
          status: 'processing',
          system_order_ref: 'provider_pending',
          amount: 1_500,
          currency: 'EUR'
        }.to_json
      )

    result = @engine.call(valid_request)

    assert_equal :unknown, result.status
    assert_equal 'unexpected_provider_status', result.error_code
  end

  def test_raises_idempotency_conflict_when_an_approved_order_payment_is_repeated_with_different_parameters
    provider_request = stub_request(:post, CHARGES_URL)
                       .to_return(status: 200, body: approved_response.to_json)

    @engine.call(valid_request)

    assert_raises(PaymentEngine::IdempotencyConflict) do
      @engine.call(valid_request.merge(amount: 2_000))
    end
    assert_requested(provider_request, times: 1)
  end

  def test_rejects_an_unknown_idempotency_decision_before_calling_the_provider
    repository = Object.new
    order_payment = Object.new
    order_payment.define_singleton_method(:reserve) do |_fingerprint|
      PaymentEngine::OrderPayment::ReservationDecision.new(status: :unexpected, result: nil)
    end
    repository.define_singleton_method(:transaction) { |&block| block.call(self) }
    repository.define_singleton_method(:find_order_payment) { |_order_payment_key| order_payment }
    repository.define_singleton_method(:save_order_payment) { |_order_payment| }
    engine = build_engine(repository:)

    error = assert_raises(RuntimeError) { engine.call(valid_request) }

    assert_equal 'unknown reservation status: :unexpected', error.message
    assert_not_requested :post, CHARGES_URL
  end

  def test_reusing_a_provider_reference_for_another_order_makes_both_order_payments_unknown
    provider_request = stub_request(:post, CHARGES_URL)
                       .to_return(status: 200, body: approved_response.to_json)

    first_result = @engine.call(valid_request)
    second_result = @engine.call(valid_request.merge(order_id: 'ord_other'))
    first_result_after_collision = @engine.call(valid_request)

    assert_equal :approved, first_result.status
    assert_equal :unknown, second_result.status
    assert_equal 'duplicate_system_order_ref', second_result.error_code
    assert_equal :unknown, first_result_after_collision.status
    assert_equal 'duplicate_system_order_ref', first_result_after_collision.error_code
    assert_requested(provider_request, times: 2)
  end

  def test_uses_the_configured_hmac_secret_when_comparing_repeated_requests
    repository = PaymentEngine::InMemoryOrderPaymentRepository.new
    first_engine = build_engine(repository:, fingerprint_secret: 'first-secret')
    second_engine = build_engine(repository:, fingerprint_secret: 'second-secret')
    provider_request = stub_request(:post, CHARGES_URL)
                       .to_return(status: 200, body: approved_response.to_json)

    first_engine.call(valid_request)

    assert_raises(PaymentEngine::IdempotencyConflict) { second_engine.call(valid_request) }
    assert_requested(provider_request, times: 1)
  end

  def test_returns_in_progress_to_a_concurrent_call_without_charging_twice
    provider_started = Queue.new
    release_provider = Queue.new
    provider_calls = 0
    provider_calls_mutex = Mutex.new
    response_body = approved_response
    provider_client = Object.new
    provider_client.define_singleton_method(:charge) do |**_payload|
      call_number = provider_calls_mutex.synchronize { provider_calls += 1 }
      if call_number == 1
        provider_started << true
        release_provider.pop
      end
      PaymentEngine::ProviderClient::ParsedResponse.new(
        status: 200,
        body: response_body,
        response_bytes: response_body.to_json.bytesize,
        response_sha256: 'response-sha256'
      )
    end
    engine = build_engine(provider_client:)

    first_call = Thread.new { engine.call(valid_request) }
    provider_started.pop
    concurrent_result = engine.call(valid_request)
    release_provider << true
    first_result = first_call.value

    assert_equal :in_progress, concurrent_result.status
    assert_equal 'request_in_progress', concurrent_result.error_code
    assert_equal :approved, first_result.status
    assert_equal 1, provider_calls
  ensure
    release_provider << true if first_call&.alive?
    first_call&.join
  end

  def test_persists_a_retryable_failure_transition_before_calling_the_provider
    request, errors = PaymentEngine::ChargeRequest.build(
      valid_request,
      fingerprint_secret: 'fingerprint-secret'
    )

    assert_empty errors
    retryable_result = PaymentEngine::PaymentResult.for_request(
      request,
      status: :retryable_failure,
      error_code: 'provider_unreachable_before_send'
    )
    repository = CopyingRepository.new(
      PaymentEngine::OrderPayment.new(
        order_payment_key: request.order_payment_key,
        fingerprint: request.fingerprint,
        result: retryable_result
      )
    )
    stub_request(:post, CHARGES_URL)
      .to_return(status: 200, body: approved_response.to_json)

    result = build_engine(repository:).call(valid_request)

    assert_equal :approved, result.status
    assert_includes repository.saved_states, nil
  end

  def test_retries_ehostunreach_before_send_failures_and_eventually_succeeds
    provider_request = stub_request(:post, CHARGES_URL)
                       .to_raise(Errno::EHOSTUNREACH.new)
                       .then.to_raise(Errno::EHOSTUNREACH.new)
                       .then.to_return(status: 200, body: approved_response.to_json)

    result = @engine.call(valid_request)

    assert_equal :approved, result.status
    assert_requested(provider_request, times: 3)
  end

  {
    'socket_error' => -> { SocketError.new('getaddrinfo failed') },
    'connection_refused' => -> { Errno::ECONNREFUSED.new },
    'network_unreachable' => -> { Errno::ENETUNREACH.new },
    'open_timeout' => -> { Net::OpenTimeout.new('execution expired') }
  }.each do |scenario, exception_factory|
    define_method("test_treats_#{scenario}_as_a_safe_before_send_retry") do
      provider_request = stub_request(:post, CHARGES_URL).to_raise(exception_factory.call)

      result = @engine.call(valid_request)

      assert_equal :retryable_failure, result.status
      assert_equal 'provider_unreachable_before_send', result.error_code
      assert_requested(provider_request, times: 3)
    end
  end

  def test_treats_a_post_send_faraday_error_as_an_ambiguous_unknown_outcome
    provider_request = stub_request(:post, CHARGES_URL)
                       .to_raise(Faraday::TimeoutError.new('net/http read timeout'))

    result = @engine.call(valid_request)

    assert_equal :unknown, result.status
    assert_equal 'provider_outcome_unknown', result.error_code
    assert_requested(provider_request, times: 1)
  end

  def test_stores_unknown_after_an_unexpected_provider_exception_and_never_leaves_the_order_payment_in_progress
    provider_request = stub_request(:post, CHARGES_URL)
                       .to_raise(RuntimeError.new('adapter exploded'))

    first_result = @engine.call(valid_request)
    repeated_result = @engine.call(valid_request)

    assert_equal :unknown, first_result.status
    assert_equal 'unexpected_provider_error', first_result.error_code
    assert_equal first_result, repeated_result
    assert_requested(provider_request, times: 1)
  end

  def test_preserves_the_provider_result_and_saved_state_when_logging_fails
    failing_logger = Object.new
    failing_logger.define_singleton_method(:info) { |_message| raise 'logger unavailable' }
    engine_with_failing_logger = build_engine(logger: failing_logger)
    provider_request = stub_request(:post, CHARGES_URL)
                       .to_return(status: 200, body: approved_response.to_json)

    first_result = engine_with_failing_logger.call(valid_request)
    repeated_result = engine_with_failing_logger.call(valid_request)

    assert_equal :approved, first_result.status
    assert_equal first_result, repeated_result
    assert_requested(provider_request, times: 1)
  end

  def test_classifies_malformed_json_and_logs_response_metadata_without_secrets
    log_sink = LogSink.new
    logged_engine = build_engine(logger: log_sink)
    stub_request(:post, CHARGES_URL)
      .to_return(status: 200, body: '{not-json')

    result = logged_engine.call(valid_request)
    classified = log_sink.events.find { |event| event[:event] == 'provider_response_classified' }

    assert_equal 'malformed_response', result.error_code
    assert_equal(
      {
        http_status: 200,
        status: 'unknown',
        error_code: 'malformed_response',
        response_bytes: 9,
        response_sha256: 'f1dec6e9ee608550bd1c39ff2b90134059bac5d02e4e78f6410aed2fbd870bd0'
      },
      classified.slice(:http_status, :status, :error_code, :response_bytes, :response_sha256)
    )
    assert_kind_of Numeric, classified.fetch(:duration_ms)
    refute_includes log_sink.events.to_json, 'tok_visa_4242'
    refute_includes log_sink.events.to_json, 'provider-secret'
    refute_includes log_sink.events.to_json, 'fingerprint-secret'
  end

  def test_returns_requires_action_only_for_a_complete_three_d_secure_response
    stub_request(:post, CHARGES_URL)
      .to_return(
        status: 200,
        body: {
          status: 'threeds_required',
          system_order_ref: 'provider_3ds',
          amount: 1_500,
          currency: 'EUR',
          threeds_url: 'https://provider.example/3ds/abc123'
        }.to_json
      )

    result = @engine.call(valid_request)

    assert_equal :requires_action, result.status
    assert_equal 'provider_3ds', result.provider_reference
    assert_equal 'https://provider.example/3ds/abc123', result.redirect_url
  end

  def test_retrying_a_requires_action_order_with_the_same_parameters_reuses_the_stored_result
    provider_request = stub_request(:post, CHARGES_URL)
                       .to_return(
                         status: 200,
                         body: {
                           status: 'threeds_required',
                           system_order_ref: 'provider_3ds',
                           amount: 1_500,
                           currency: 'EUR',
                           threeds_url: 'https://provider.example/3ds/abc123'
                         }.to_json
                       )

    first_result = @engine.call(valid_request)
    second_result = @engine.call(valid_request)

    assert_equal :requires_action, second_result.status
    assert_equal first_result, second_result
    assert_requested(provider_request, times: 1)
  end

  def test_returns_declined_only_for_the_documented_card_declined_response
    stub_request(:post, CHARGES_URL)
      .to_return(status: 422, body: { status: 'error', reason: 'card_declined' }.to_json)

    result = @engine.call(valid_request)

    assert_equal :declined, result.status
    assert_equal 'card_declined', result.error_code
  end

  def test_retrying_a_declined_order_with_the_same_parameters_reuses_the_stored_result
    provider_request = stub_request(:post, CHARGES_URL)
                       .to_return(status: 422, body: { status: 'error', reason: 'card_declined' }.to_json)

    first_result = @engine.call(valid_request)
    second_result = @engine.call(valid_request)

    assert_equal :declined, second_result.status
    assert_equal first_result, second_result
    assert_requested(provider_request, times: 1)
  end

  def test_retrying_a_declined_order_with_different_parameters_raises_idempotency_conflict
    stub_request(:post, CHARGES_URL)
      .to_return(status: 422, body: { status: 'error', reason: 'card_declined' }.to_json)

    @engine.call(valid_request)

    assert_raises(PaymentEngine::IdempotencyConflict) do
      @engine.call(valid_request.merge(amount: 2_000))
    end
  end

  {
    'http_500' => [500, { status: 'error' }.to_json, 'provider_server_error'],
    'http_authentication_failure' => [401, { status: 'error' }.to_json, 'provider_authentication_error'],
    'unexpected_http_status' => [418, { status: 'teapot' }.to_json, 'unexpected_http_status'],
    'empty_response' => [200, '', 'empty_response'],
    'unknown_decline_reason' => [422, { status: 'error', reason: 'processing_error' }.to_json,
                                 'unexpected_decline_reason'],
    'missing_provider_reference' => [200, { status: 'approved', amount: 1_500, currency: 'EUR' }.to_json,
                                     'incomplete_response'],
    'amount_mismatch' => [
      200,
      { status: 'approved', system_order_ref: 'provider_1', amount: 2_000, currency: 'EUR' }.to_json,
      'amount_mismatch'
    ],
    'currency_mismatch' => [
      200,
      { status: 'approved', system_order_ref: 'provider_1', amount: 1_500, currency: 'USD' }.to_json,
      'currency_mismatch'
    ],
    'three_d_secure_url_with_userinfo' => [
      200,
      {
        status: 'threeds_required',
        system_order_ref: 'provider_3ds',
        amount: 1_500,
        currency: 'EUR',
        threeds_url: 'https://user:password@provider.example/3ds'
      }.to_json,
      'invalid_redirect_url'
    ],
    'three_d_secure_url_malformed' => [
      200,
      {
        status: 'threeds_required',
        system_order_ref: 'provider_3ds',
        amount: 1_500,
        currency: 'EUR',
        threeds_url: 'https://exa mple.com/3ds'
      }.to_json,
      'invalid_redirect_url'
    ]
  }.each do |scenario, (http_status, body, error_code)|
    define_method("test_keeps_#{scenario}_unknown_without_resubmitting") do
      provider_request = stub_request(:post, CHARGES_URL)
                         .to_return(status: http_status, body:)

      first_result = @engine.call(valid_request)
      repeated_result = @engine.call(valid_request)

      assert_equal :unknown, first_result.status
      assert_equal error_code, first_result.error_code
      assert_equal first_result, repeated_result
      assert_requested(provider_request, times: 1)
    end
  end
end
