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

    # Raised by PiNetwork::SmartContract::Subscription.process. code says what went wrong; txid is set once a
    # transaction exists (with :transaction_not_confirmed it may still land: look it up before sending again).
    class SubscriptionError < StandardError
      MESSAGES = {
        invalid_merchant_secret: "Merchant secret must be a valid secret seed (S...).",
        invalid_service_id: "Service ID must be a non-negative integer that fits in a u64.",
        invalid_offset: "Offset must be an integer in 0..4294967295.",
        invalid_limit: "Limit must be an integer in 0..4294967295.",
        invalid_mode: "Mode must be :simulate or :submit.",
        invalid_timeout: "timeout_seconds must be a positive integer.",
        invalid_rpc_url: "rpc_url must be an http(s) URL.",
        invalid_network_passphrase: "network_passphrase must be a non-empty String.",
        invalid_contract_address: "Contract address must be a contract address (C...).",
        account_not_found: "The merchant account does not exist on this network.",
        state_archived: "Contract state needed by this call is archived and must be restored first.",
        simulation_failed: "The process call failed in simulation.",
        fee_too_high: "The fee is higher than a transaction can carry.",
        transaction_rejected: "The RPC server did not accept the transaction.",
        transaction_failed: "The transaction failed on chain.",
        transaction_not_confirmed: "The transaction was sent but its outcome is not known yet.",
        unexpected_response: "The RPC server returned something the SDK could not read.",
        rpc_error: "The RPC server request failed."
      }.freeze

      attr_reader :code
      attr_reader :txid
      attr_reader :contract_error_code
      attr_reader :contract_error_name
      attr_reader :detail

      def initialize(code, txid: nil, contract_error_code: nil, contract_error_name: nil, detail: nil)
        contract = contract_error_name ? " #{contract_error_name} (##{contract_error_code})" : ""
        super(MESSAGES.fetch(code, "Subscription processing failed.") + contract)
        @code = code
        @txid = txid
        @contract_error_code = contract_error_code
        @contract_error_name = contract_error_name
        @detail = detail
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