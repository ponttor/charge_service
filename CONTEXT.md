# Payment Engine Context

This context describes the language of the service that accepts charge requests from merchants and talks to an external payment provider.

## Language

**Order identifier (`order_id`)**:
A unique order identifier within a specific merchant's system. Within the payment service, an order is uniquely identified by the pair `merchant_id` and `order_id`.
_Avoid_: global order identifier, provider operation identifier

**Order payment**:
The lifecycle of collecting payment for a single order, uniquely identified by the pair `merchant_id` and `order_id`. May include several sequential charge attempts, if it is reliably known that the previous one did not result in a charge.
_Avoid_: charge attempt, individual request-delivery attempt

**Charge attempt**:
An intent to charge a given amount in a given currency against a specific payment instrument, within the scope of an order payment. Technical retries of delivering the same request do not create a new charge attempt.
_Avoid_: order payment, individual request-delivery attempt

**Charge amount (`amount`)**:
A positive integer number of the minor units of the chosen currency.
_Avoid_: fractional monetary value, amount in major currency units

**Currency (`currency`)**:
A three-letter, upper-case currency code. Whether a specific currency is supported is determined by the payment provider.
_Avoid_: currency name, lower-case code

**Card token (`card_token`)**:
An opaque identifier for a tokenized payment instrument. Its value never changes and is handled as sensitive.
_Avoid_: card number, normalized token

**Provider operation identifier (`system_order_ref`)**:
A unique identifier for the charge attempt within the payment provider's system.
_Avoid_: merchant order identifier, `order_id`

**In progress (`IN_PROGRESS`)**:
A transient state returned to a concurrent call while another charge attempt for the same order payment is already underway. It is never persisted as an attempt's outcome and is not a provider status.
_Avoid_: `PROCESSING`, undetermined outcome, approval, decline

**Requires action (`REQUIRES_ACTION`)**:
An unfinished state of a charge attempt in which the customer must complete additional authentication (e.g. 3DS) via an HTTPS link supplied by the provider. It neither confirms nor denies the charge.
_Avoid_: `THREEDS_REQUIRED`, approval, decline, undetermined outcome

**Undetermined outcome**:
A final outcome of a charge attempt in which it is unknown whether the charge occurred at the payment provider. This is neither an approval nor a decline.
_Avoid_: payment error, decline, failed payment

**Approved charge**:
A final outcome of a charge attempt for which the provider has given an unambiguous confirmation, carrying its own reference and the amount and currency of the original request.
_Avoid_: any HTTP 200 response, presumed successful charge

**Declined charge**:
A final outcome of a charge attempt for which there is unambiguous confirmation that the charge did not occur. A technically unclear response is not a decline.
_Avoid_: undetermined outcome, any provider error
