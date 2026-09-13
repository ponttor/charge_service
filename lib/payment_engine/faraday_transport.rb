require 'digest'
require 'faraday'

class PaymentEngine
  class FaradayTransport
    Response = Data.define(:status, :body, :response_bytes, :response_sha256)

    def initialize(
      open_timeout: 2,
      read_timeout: 5,
      write_timeout: 5,
      connection: Faraday.new
    )
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @write_timeout = write_timeout
      @connection = connection
    end

    def post(uri:, headers:, body:)
      perform_post(uri, headers, body)
    rescue Faraday::Error => error
      classify_and_raise(error)
    end

    private

    def perform_post(uri, headers, body)
      response = @connection.post(uri) do |request|
        request.headers.update(headers)
        request.body = body
        request.options.open_timeout = @open_timeout
        request.options.read_timeout = @read_timeout
        request.options.write_timeout = @write_timeout
      end

      Response.new(
        status: response.status,
        body: response.body,
        response_bytes: response.body.bytesize,
        response_sha256: Digest::SHA256.hexdigest(response.body)
      )
    end

    def classify_and_raise(error)
      raise(error.wrapped_exception || error)
    rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
           Errno::ENETUNREACH, Net::OpenTimeout => original
      raise BeforeSendError, original.message
    rescue StandardError => original
      raise AmbiguousTransportError, original.message
    end
  end
end
