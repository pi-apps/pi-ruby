class ::PiNetwork
  module Errors
    class APIRequestError < StandardError
      attr_reader :response_body
      attr_reader :response_status
      def initialize(message, response_status, response_body)
        super(message)
        @response_status = response_status
        @response_body = response_body
      end
    end

    class PaymentNotFoundError < StandardError
      attr_reader :payment_id
      def initialize(message, payment_id)
        super(message)
        @payment_id = payment_id
      end
    end
  end
end