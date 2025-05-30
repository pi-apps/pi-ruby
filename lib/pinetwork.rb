require_relative 'errors'

class PiNetwork
  require 'faraday'
  require 'json'
  require 'stellar-sdk'

  attr_reader :api_key
  attr_reader :client
  attr_reader :account
  attr_reader :base_url
  attr_reader :from_address

  BASE_URL = "https://api.minepi.com".freeze
  MAINNET_HOST = "api.mainnet.minepi.com".freeze
  TESTNET_HOST = "api.testnet.minepi.com".freeze
  TX_SUBMISSION_TIMEOUT_SECONDS = 30
  TX_RETRY_DELAY_SECONDS = 5

  def initialize(api_key:, wallet_private_key:, faraday: Faraday.new, options: {})
    validate_private_seed!(wallet_private_key)

    @api_key = api_key
    @account = load_account(wallet_private_key)
    @base_url = options[:base_url] || BASE_URL
    @mainnet_host = options[:mainnet_host] || MAINNET_HOST
    @testnet_host = options[:testnet_host] || TESTNET_HOST
    @faraday = faraday

    @open_payments = {}
    @open_payments_mutex = Mutex.new
  end

  def get_payment(payment_id)
    response = Faraday.get(
      base_url + "/v2/payments/#{payment_id}",
      {},
      http_headers,
    )

    if response.status == 404
      raise Errors::PaymentNotFoundError.new("Payment not found", payment_id)
    end

    handle_http_response(response, "An unknown error occurred while fetching the payment")
  end

  def create_payment(payment_data)
    validate_payment_data!(payment_data, {amount: true, memo: true, metadata: true, uid: true})

    request_body = {
      payment: payment_data,
    }

    response = @faraday.post(
      base_url + "/v2/payments",
      request_body.to_json,
      http_headers,
    )

    parsed_response = handle_http_response(response, "An unknown error occurred while creating a payment")

    identifier = parsed_response["identifier"]
    @open_payments_mutex.synchronize do
      @open_payments[identifier] = parsed_response
    end

    return identifier
  end

  def submit_payment(payment_id)
    @open_payments_mutex.synchronize do
      payment = @open_payments[payment_id]

      if payment.nil? || payment["identifier"] != payment_id
        payment = get_payment(payment_id)
        txid = payment["transaction"]&.dig("txid")
        raise Errors::TxidAlreadyLinkedError.new("This payment already has a linked txid", payment_id, txid) if txid.present?
      end

      set_horizon_client(payment["network"])
      @from_address = payment["from_address"]

      transaction_data = {
        amount: BigDecimal(payment["amount"].to_s),
        identifier: payment["identifier"],
        recipient: payment["to_address"]
      }

      transaction = build_a2u_transaction(transaction_data)
      txid = submit_transaction(transaction)

      @open_payments.delete(payment_id)

      return txid
    end
  end

  def complete_payment(payment_id, txid)
    body = {"txid": txid}

    response = Faraday.post(
      base_url + "/v2/payments/#{payment_id}/complete",
      body.to_json,
      http_headers
    )

    @open_payments_mutex.synchronize do
      @open_payments.delete(payment_id)
    end

    handle_http_response(response, "An unknown error occurred while completing the payment")
  end

  def cancel_payment(payment_id)
    response = Faraday.post(
      base_url + "/v2/payments/#{payment_id}/cancel",
      {}.to_json,
      http_headers,
    )

    @open_payments_mutex.synchronize do
      @open_payments.delete(payment_id)
    end

    handle_http_response(response, "An unknown error occurred while cancelling the payment")
  end

  def get_incomplete_server_payments
    response = Faraday.get(
      base_url + "/v2/payments/incomplete_server_payments",
      {},
      http_headers,
    )

    res = handle_http_response(response, "An unknown error occurred while fetching incomplete payments")
    res["incomplete_server_payments"]
  end

  private

  def http_headers
    return nil if @api_key.nil?

    {
      "Authorization": "Key #{@api_key}",
      "Content-Type": "application/json"
    }
  end

  def handle_http_response(response, unknown_error_message = "An unknown error occurred while making an API request")
    unless response.status == 200
      error_message = extract_error_message(response.body, unknown_error_message)
      raise Errors::APIRequestError.new(error_message, response.status, response.body)
    end

    begin
      parsed_response = JSON.parse(response.body)
      return parsed_response
    rescue StandardError => err
      error_message = "Failed to parse response body"
      raise Errors::APIRequestError.new(error_message, response.status, response.body)
    end
  end

  def set_horizon_client(network)
    host = (network.start_with? "Pi Network") ? @mainnet_host : @testnet_host
    horizon = "https://#{host}"

    client = Stellar::Horizon::Client.new(host: host, horizon: horizon)
    Stellar::default_network = network

    @client = client
  end

  def load_account(private_seed)
    account = Stellar::Account.from_seed(private_seed)
  end

  def build_a2u_transaction(transaction_data)
    raise StandardError.new("You should use a private seed of your app wallet!") if self.from_address != self.account.address

    validate_payment_data!(transaction_data, {amount: true, identifier: true, recipient: true})

    amount = Stellar::Amount.new(transaction_data[:amount])
    # TODO: get this from horizon
    fee = 100000 # 0.01π
    recipient = Stellar::KeyPair.from_address(transaction_data[:recipient])
    memo = Stellar::Memo.new(:memo_text, transaction_data[:identifier])

    # Add time_bounds so we can place a time limit on the transaction and try the same
    # one multiple times (in case of Horizon server errors)
    min_time = Time.now.utc.to_i
    max_time = min_time + TX_SUBMISSION_TIMEOUT_SECONDS
    time_bounds = Stellar::TimeBounds.new(min_time:, max_time:)

    payment_operation = Stellar::Operation.payment(destination: recipient, amount: amount.to_payment)

    my_public_key = self.account.address
    sequence_number = self.client.account_info(my_public_key).sequence.to_i
    transaction_builder = Stellar::TransactionBuilder.new(
      source_account: self.account.keypair,
      sequence_number: sequence_number + 1,
      base_fee: fee,
      memo: memo,
      time_bounds: time_bounds
    )

    transaction = transaction_builder.add_operation(payment_operation).build
  end

  def parse_horizon_error_response(body)
    result_codes = body&.dig("extras", "result_codes")
    tx_error_code = result_codes&.dig("transaction") || "unknown"
    op_error_code = result_codes&.dig("operations") || "unknown"

    return tx_error_code, op_error_code
  end

  def submit_transaction(transaction)
    envelope = transaction.to_envelope(self.account.keypair)
    begin
      response = self.client.submit_transaction(tx_envelope: envelope)
      txid = response._response.body["id"]

      return txid if txid.present?

      status = response._response.body["status"]
      error_type = status / 100 # 4 == client-side error; 5 == server-side error

      if error_type == 4 # Raise the error immediately; something is wrong on our end...
        tx_error_code, op_error_code = parse_horizon_error_response(response._response.body)

        # ...UNLESS it's tx_too_early...then just wait and try again as if it were a server-side error
        raise Errors::TxSubmissionError.new(tx_error_code, op_error_code) unless tx_error_code == "tx_too_early"
      elsif error_type != 5 # Some unexpected_status_code
        # Repurposing TxSubmissionError here so we don't have to make a new Error for an unlikely response to encounter
        raise Errors::TxSubmissionError.new("unexpected_response_code", [status])
      end

      # Server-side error
      # Wait a moment, then try the tx again
      # If we're past the time bounds we'll receive a 400 response and raise an exception
      sleep TX_RETRY_DELAY_SECONDS

      submit_transaction(transaction)
    rescue Errors::TxSubmissionError => error
      # No need to parse the response if we already formatted the exception in the `begin` block
      raise error
    rescue => error
      tx_error_code, op_error_code = parse_horizon_error_response(error&.response&.dig(:body))
      raise Errors::TxSubmissionError.new(tx_error_code, op_error_code)
    end
  end

  def validate_payment_data!(data, options = {})
    raise ArgumentError.new("Missing amount") if options[:amount] && !data[:amount].present?
    raise ArgumentError.new("Missing memo") if options[:memo] && !data[:memo].present?
    raise ArgumentError.new("Missing metadata") if options[:metadata] && !data[:metadata].present?
    raise ArgumentError.new("Missing uid") if options[:uid] && !data[:uid].present?
    raise ArgumentError.new("Missing identifier") if options[:identifier] && !data[:identifier].present?
    raise ArgumentError.new("Missing recipient") if options[:recipient] && !data[:recipient].present?
  end

  def validate_private_seed!(seed)
    begin
      Stellar::Util::StrKey.check_decode(:seed, seed)
    rescue StandardError
      raise StandardError.new("Invalid Private Seed")
    end
  end

  def extract_error_message(response_body, default_message)
    JSON.parse(response_body).dig("error_message") rescue default_message
  end
end
