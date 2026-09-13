# Safe handling of retries and undetermined outcomes

The provider documents no idempotency key, status check, or webhook, so retrying after a request that may already have been sent risks a double charge. We identify an order payment by the pair `(merchant_id, order_id)`, register it atomically before contacting the provider, and do not retry a request that may have been sent: such a result becomes `UNKNOWN` and, within the integration available to us, stays final. Reuse of a `system_order_ref` across different orders is likewise treated as ambiguous, so that one provider operation can never confirm two payments.

Automatic retry is allowed only for a proven failure that occurred before the request was sent, and is capped at three attempts per `call` invocation, with exponential backoff and jitter. Once safe retries are exhausted, `RETRYABLE_FAILURE` is returned; a later call may try again. A new charge attempt with changed parameters for the same order is permitted only after `DECLINED` or `RETRYABLE_FAILURE`, when it is reliably known that no charge occurred; the history of attempts is preserved without being overwritten.

## Consequences

The strategy favors preventing a double charge over automatically recovering doubtful operations, so some payments will require external reconciliation. The take-home uses an atomic, thread-safe in-memory store; a production implementation must provide the same model in durable storage, with order-payment uniqueness enforced across service instances.
