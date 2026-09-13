require_relative 'test_helper'
require 'digest'

class ProviderClientTest < Minitest::Test
  TransportStub = Struct.new(:response, :requests) do
    def post(**request)
      requests << request
      response
    end
  end

  TransportResponse = Data.define(:status, :body, :response_bytes, :response_sha256)

  def test_builds_authenticated_json_charge_request
    body = '{"status":"approved","system_order_ref":"provider_1","amount":1500,"currency":"EUR"}'
    transport = TransportStub.new(
      TransportResponse.new(
        status: 200,
        body:,
        response_bytes: body.bytesize,
        response_sha256: Digest::SHA256.hexdigest(body)
      ),
      []
    )
    client = PaymentEngine::ProviderClient.new(token: 'secret', transport:)

    response = client.charge(amount: 1_500, currency: 'EUR', card_token: 'tok_visa_4242')

    assert_equal 200, response.status
    assert_equal 'approved', response.body[:status]
    assert_equal(
      {
        uri: URI('https://api.paymentprovider.com/charges'),
        headers: {
          'Authorization' => 'Bearer secret',
          'Content-Type' => 'application/json',
          'Accept' => 'application/json'
        },
        body: '{"amount":1500,"currency":"EUR","card_token":"tok_visa_4242"}'
      },
      transport.requests.fetch(0)
    )
  end
end
