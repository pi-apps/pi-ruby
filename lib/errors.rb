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
  end
end