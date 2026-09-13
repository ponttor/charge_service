# Payment Engine — Take-Home Task

## Context

You're building part of a payment engine. When a merchant wants to charge a customer, your service sends a request to an external payment provider (acquirer).

In the real world, provider documentation is often incomplete or outdated, and support response times can be measured in days. You need to build a service that handles what the provider sends back — and also what it doesn't — in a way that avoids money loss and maximizes conversion.

We assume that provided docs are correct, but there might be different responses from the provider which are not mentioned.

---

## Provider Documentation

You don't need to call a real API. Build the provider call as you would for a real HTTP request, and stub it in tests to simulate different outcomes.

**Base URL:** `https://api.paymentprovider.com`  
**Authentication:** Bearer token  

### POST /charges

**Request:**
```json
{
  "amount": 1500,
  "currency": "EUR",
  "card_token": "tok_visa_4242"
}
```

**Success responses (HTTP 200):**

```json
{
  "status": "approved",
  "system_order_ref": "ord_98f7a6b5c4d3",
  "amount": 1500,
  "currency": "EUR"
}
```

```json
{
  "status": "threeds_required",
  "system_order_ref": "ord_11e2f3a4b5c6",
  "amount": 1500,
  "currency": "EUR",
  "threeds_url": "https://provider.example/3ds/abc123"
}
```

**Error response (HTTP 422):**
```json
{
  "status": "error",
  "reason": "card_declined"
}
```

> This is all the documentation you have. What actually happens in production is up to you to consider.

---

## What to Build

A service with one public method: `call(request_params)`

**Request params:**
```ruby
{
  merchant_id: "merchant_42",
  order_id: "ord_abc123",
  amount: 1500,               # in cents
  currency: "EUR",
  card_token: "tok_visa_4242"  # tokenized card, not real card data
}
```

**Your service should:**

1. Validate the request
2. Make a request to the provider and handle the response
3. Log meaningful events — what happened, why, and enough context to debug in production

> Design your service assuming real money is involved and the provider is not your friend.

---

## What to Deliver

1. The service code
2. Tests that cover the scenarios you consider most important — stub the provider call to simulate different outcomes
3. A short README: your key decisions, what you'd do differently in production, anything you intentionally skipped

---

## What We're NOT Looking For

- HTTP layer / framework
- Fully working app
- Real database — in-memory storage is fine
- Performance tuning

---

## Language & Time

**Language:** Ruby is preferred. If you're stronger in another backend language, that's okay — we'll expect you to pick up Ruby during probation.

**Time:** 1.5–2 hours.

We want to see a working solution covered by tests. If you're running out of time, it's better to deliver something that runs end to end with good test coverage and skip some edge cases than to cover everything but leave it half-built. Describe what you skipped and how you'd handle it in the README.
