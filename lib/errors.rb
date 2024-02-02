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

    class TxidAlreadyLinkedError < StandardError
      attr_reader :payment_id
      attr_reader :txid

      def initialize(message, payment_id, txid)
        super(message)
        @payment_id = payment_id
        @txid = txid
      end
    end

    class TxSubmissionError < StandardError
      attr_reader :tx_error_code
      attr_reader :op_error_codes

      def initialize(tx_error_code, op_error_codes)
        super(message)
        @tx_error_code = tx_error_code
        @op_error_codes = op_error_codes
      end
    end
  end
end