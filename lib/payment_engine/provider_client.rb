require 'json'
require 'uri'

class PaymentEngine
  class ProviderClient
    ParsedResponse = Data.define(:status, :body, :response_bytes, :response_sha256)

    def initialize(token:, base_url: 'https://api.paymentprovider.com', transport: FaradayTransport.new)
      @token = token
      @base_url = base_url
      @transport = transport
    end

    def charge(amount:, currency:, card_token:)
      transport_response = @transport.post(
        uri: URI.join("#{@base_url}/", 'charges'),
        headers: {
          'Authorization' => "Bearer #{@token}",
          'Content-Type' => 'application/json',
          'Accept' => 'application/json'
        },
        body: JSON.generate(amount:, currency:, card_token:)
      )

      ParsedResponse.new(
        status: transport_response.status,
        body: parse_body(transport_response.body),
        response_bytes: transport_response.response_bytes,
        response_sha256: transport_response.response_sha256
      )
    end

    private

    def parse_body(body)
      JSON.parse(body, symbolize_names: true)
    rescue JSON::ParserError
      body
    end
  end
end
