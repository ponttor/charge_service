class PaymentEngine
  BeforeSendError = Class.new(StandardError)
  AmbiguousTransportError = Class.new(StandardError)

  class InvalidRequest < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors.freeze
      super('invalid payment request')
    end
  end

  IdempotencyConflict = Class.new(StandardError)
end
