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

    class WalletPrivateKeyNotFoundError < StandardError
    end
  end
end