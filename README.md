# Payment Engine

A small Ruby service that validates merchant charge requests, calls an external payment provider, and preserves enough state to make retries safe when real money is involved.

## Run the tests

Ruby 3.2 or newer is required (`Data.define` is used). The test suite uses Minitest.

```sh
bundle install
bundle exec rake test
```

## Usage

```ruby
require "logger"
require_relative "lib/payment_engine"

provider = PaymentEngine::ProviderClient.new(token: ENV.fetch("PAYMENT_PROVIDER_TOKEN"))
engine = PaymentEngine.new(
  provider_client: provider,
  logger: Logger.new($stdout),
  fingerprint_secret: ENV.fetch("PAYMENT_FINGERPRINT_SECRET")
)

result = engine.call(
  merchant_id: "merchant_42",
  order_id: "ord_abc123",
  amount: 1_500,
  currency: "EUR",
  card_token: "tok_visa_4242"
)

puts result.status
```

## Response

`PaymentEngine#call` returns an immutable `PaymentResult`, or raises for caller errors (see below). Its fields:

| Field | Description |
| --- | --- |
| `status` | One of the statuses below. |
| `merchant_id`, `order_id`, `amount`, `currency` | Echoed back from the request. |
| `provider_reference` (alias `system_order_ref`) | The provider's reference for the charge, when one exists. |
| `redirect_url` (alias `threeds_url`) | HTTPS URL the merchant must send the shopper to, only set for `requires_action`. |
| `error_code` (alias `reason`) | Machine-readable reason, set for `declined`, `retryable_failure`, `unknown`, and `in_progress`. |
| `error_message` | Reserved for a human-readable detail; currently always `nil` — nothing in the engine sets it yet, so treat `error_code` as the only reason to branch on. |

`result.retryable_failure?` is a shorthand for `status == :retryable_failure`.

Possible values of `status`:

| Status | Meaning |
| --- | --- |
| `approved` | The provider confirmed the charge succeeded. |
| `requires_action` | The shopper must complete 3DS at `redirect_url`/`threeds_url`; the payment is still open. |
| `declined` | The provider returned the documented `422 card_declined` response; terminal. |
| `retryable_failure` | All three attempts failed before a request could be sent; proven not sent, so a new charge attempt is allowed. |
| `unknown` | A request may have been sent but its outcome can't be established, or the response can't be trusted; check `error_code` (e.g. `malformed_response`, `duplicate_system_order_ref`). |
| `in_progress` | A concurrent call for the same order is already running; not persisted, safe to retry the call later. |

### Examples

Same call as in Usage, shown for each possible outcome — this time printing the whole result the merchant gets back:

**Charge succeeded — capture is done, ship the order.**
```ruby
result = engine.call(
  merchant_id: "merchant_42",
  order_id: "ord_abc123",
  amount: 1_500,
  currency: "EUR",
  card_token: "tok_visa_4242"
)

pp result
# =>
# #<data PaymentEngine::PaymentResult
#  status=:approved,
#  merchant_id="merchant_42",
#  order_id="ord_abc123",
#  amount=1500,
#  currency="EUR",
#  provider_reference="provider_1",
#  redirect_url=nil,
#  error_code=nil,
#  error_message=nil>
```

**Card needs 3-D Secure — redirect the shopper, order is still open.**
```ruby
result = engine.call(
  merchant_id: "merchant_42",
  order_id: "ord_3ds001",
  amount: 1_500,
  currency: "EUR",
  card_token: "tok_visa_4242"
)

pp result
# =>
# #<data PaymentEngine::PaymentResult
#  status=:requires_action,
#  merchant_id="merchant_42",
#  order_id="ord_3ds001",
#  amount=1500,
#  currency="EUR",
#  provider_reference="provider_3ds",
#  redirect_url="https://provider.example/3ds/abc123",
#  error_code=nil,
#  error_message=nil>
```

**Card was declined — terminal, ask the shopper for a different card.**
```ruby
result = engine.call(
  merchant_id: "merchant_42",
  order_id: "ord_declined01",
  amount: 1_500,
  currency: "EUR",
  card_token: "tok_visa_0002"
)

pp result
# =>
# #<data PaymentEngine::PaymentResult
#  status=:declined,
#  merchant_id="merchant_42",
#  order_id="ord_declined01",
#  amount=1500,
#  currency="EUR",
#  provider_reference=nil,
#  redirect_url=nil,
#  error_code="card_declined",
#  error_message=nil>
```

**Never reached the provider (network down before the request could send) — safe to call again with the same params.**
```ruby
result = engine.call(
  merchant_id: "merchant_42",
  order_id: "ord_timeout01",
  amount: 1_500,
  currency: "EUR",
  card_token: "tok_visa_4242"
)

pp result
# =>
# #<data PaymentEngine::PaymentResult
#  status=:retryable_failure,
#  merchant_id="merchant_42",
#  order_id="ord_timeout01",
#  amount=1500,
#  currency="EUR",
#  provider_reference=nil,
#  redirect_url=nil,
#  error_code="provider_unreachable_before_send",
#  error_message=nil>
```

**Can't tell what happened (unrecognized/inconsistent provider response, ambiguous transport error, duplicated provider reference, ...) — do NOT auto-retry; needs a human or a reconciliation job to check with the provider first.**
```ruby
result = engine.call(
  merchant_id: "merchant_42",
  order_id: "ord_ambiguous1",
  amount: 1_500,
  currency: "EUR",
  card_token: "tok_visa_4242"
)

pp result
# =>
# #<data PaymentEngine::PaymentResult
#  status=:unknown,
#  merchant_id="merchant_42",
#  order_id="ord_ambiguous1",
#  amount=1500,
#  currency="EUR",
#  provider_reference=nil,
#  redirect_url=nil,
#  error_code="provider_outcome_unknown",
#  error_message=nil>
```

**Another call for the same order is already in flight — try again shortly, nothing was charged twice.**
```ruby
result = engine.call(
  merchant_id: "merchant_42",
  order_id: "ord_abc123",
  amount: 1_500,
  currency: "EUR",
  card_token: "tok_visa_4242"
)

pp result
# =>
# #<data PaymentEngine::PaymentResult
#  status=:in_progress,
#  merchant_id="merchant_42",
#  order_id="ord_abc123",
#  amount=1500,
#  currency="EUR",
#  provider_reference=nil,
#  redirect_url=nil,
#  error_code="request_in_progress",
#  error_message=nil>
```

Instead of returning a result, `#call` raises:

- `PaymentEngine::InvalidRequest` (with an `#errors` hash) when the request is not a hash, has unknown/duplicate/missing keys, or fails field validation;
- `PaymentEngine::IdempotencyConflict` when an existing order payment is repeated with different parameters.

## Payment flow

`PaymentEngine#call` is deliberately a short orchestration method. It names the business stages without exposing repository transactions or provider-response parsing:

```ruby
request, errors = ChargeRequest.build(request_params, fingerprint_secret: @fingerprint_secret)
raise InvalidRequest, errors if errors.any?

reservation = @order_payment_registry.reserve(request)
return resolve_reservation(request, reservation) unless reservation.reserved?

provider_result = @provider_gateway.charge(request)
stored_result = @order_payment_registry.record_result(request.order_payment_key, provider_result)
stored_result
```

The collaborators divide responsibilities as follows:

- `ChargeRequest` validates and normalizes merchant input and derives the order-payment key and request fingerprint;
- `OrderPaymentRegistry` owns the atomic reservation and result-recording workflows;
- `OrderPayment` owns state transitions for one order payment and returns an explicit `OrderPayment::ReservationDecision` value instead of a positional array;
- `InMemoryOrderPaymentRepository` is a persistence adapter: transactions, order-payment storage, and the provider-reference index;
- `ProviderGateway` performs the provider charge with the safe retry policy and produces a `PaymentResult`;
- `ProviderResponseClassifier` conservatively classifies the provider response.

The two result names in the main flow are intentional: `provider_result` is what the provider gateway concluded, while `stored_result` is the canonical value after storage has checked provider-reference uniqueness.

See the [Response](#response) section above for the full set of return values and exceptions.

## Key decisions

- A payment is identified by `(merchant_id, order_id)` and registered atomically before contacting the provider. Each validated request is represented by an immutable value object; the card token is retained only in memory for provider delivery and a one-way HMAC request fingerprint (`fingerprint_secret`).
- Completed or unfinished payments are never submitted again — any stored result other than `retryable_failure` is returned as-is on repeat, including `requires_action`: it's still open from the shopper's perspective (3DS not yet completed), but the reservation itself treats it exactly like a terminal result and never resubmits. A new charge operation is allowed only after `retryable_failure` (proven not sent); `declined` is a stable terminal result, and repeating it with the same fingerprint returns the stored result instead of contacting the provider again. Repeating any prior operation with a different fingerprint always raises `IdempotencyConflict`, regardless of that operation's status.
- Only failures proven to occur before sending are retried. The service makes at most three attempts with exponential backoff and jitter. Read/write failures and other ambiguous transport outcomes become final `unknown` results. Outbound calls go through `ProviderClient`/`FaradayTransport` with explicit timeouts (2s open, 5s read/write) and a Bearer-token header; the transport layer is what classifies a raw network exception into "before send" vs. "ambiguous" for the retry policy above.
- Provider success data is trusted only when `system_order_ref` is present and `amount` and `currency` exactly match the request. A 3DS URL must use HTTPS with no userinfo. Only the documented `422/card_declined` response is treated as a decline; undocumented errors remain `unknown`.
- Reusing one `system_order_ref` for different orders makes both stored results unknown (`duplicate_system_order_ref`).
- Logs are structured JSON and deliberately exclude `card_token`, the provider token, and the fingerprint secret; a broken or unavailable logger can never affect the payment outcome — logging exceptions are swallowed, not propagated.

## Intentionally limited

The repository is in memory, so state disappears on restart and is not shared between processes. In production it should be replaced by a transactional database implementation with unique constraints for payment keys and provider references, while preserving the same atomic operations.

The provider documentation offers no idempotency key, status endpoint, or webhook. Because of that, `requires_action`, 3DS completion, and `unknown` outcomes cannot be reconciled here. A production integration should add provider-side idempotency and asynchronous reconciliation as soon as the provider supports them.

Production code would also add metrics and tracing, secret management, bounded log delivery, configuration for timeouts, persistent operation history, and integration/contract tests against a provider sandbox. No HTTP server or framework is included, as requested by the task.

A thin controller wrapping `PaymentEngine#call` would map its domain `status`/exceptions to HTTP responses roughly like this:

| `status` / exception | Suggested HTTP status | Why |
| --- | --- | --- |
| `approved` | 200 | Charge succeeded. |
| `requires_action` | 200 (body carries `redirect_url`) | Not an error — caller must redirect the shopper. |
| `declined` | 402 Payment Required | Terminal, caller's fault (the card), not the server's. |
| `retryable_failure` | 503 Service Unavailable | Nothing was sent; safe for the caller to retry, ideally with `Retry-After`. |
| `unknown` | 500 or 202 Accepted | Outcome unresolved; needs reconciliation, not an automatic retry. |
| `in_progress` | 409 Conflict | A duplicate concurrent request; caller should back off and re-check. |
| `PaymentEngine::InvalidRequest` | 422 Unprocessable Entity | Malformed/invalid request body. |
| `PaymentEngine::IdempotencyConflict` | 409 Conflict | Same order id reused with different parameters. |
