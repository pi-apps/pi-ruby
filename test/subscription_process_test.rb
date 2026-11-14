require 'minitest/autorun'
require 'mocha/minitest'
require 'ostruct'
require_relative '../lib/pinetwork'

Subscription = PiNetwork::SmartContract::Subscription
Xdr = PiNetwork::SmartContract::Xdr
SubscriptionError = PiNetwork::Errors::SubscriptionError

# A Faraday stand-in for the Soroban RPC server: answers each JSON-RPC method from a table of handlers and records
# every request, so a test can inspect what was sent.
class FakeRpc
  attr_reader :requests

  def initialize(handlers)
    @handlers = handlers
    @requests = []
  end

  def post(_url, body, _headers)
    request = JSON.parse(body)
    @requests << request
    handler = @handlers.fetch(request["method"]) { raise "unexpected RPC call #{request['method']}" }
    result = handler.respond_to?(:call) ? handler.call(request["params"]) : handler
    OpenStruct.new(status: 200, body: { jsonrpc: "2.0", id: 1, result: result }.to_json)
  end

  def calls(method)
    @requests.select { |r| r["method"] == method }
  end
end

class SubscriptionProcessTest < Minitest::Test
  CONTRACT = "CCUF75B6W3HRJTJD6O7OXNI72HGJ7DERZ5MUNOMFMSK23ME5GUIKPFYV".freeze
  RESULT = { charged: 2, failed: 1, skipped: 3, total: 6 }.freeze

  def setup
    @merchant = Stellar::KeyPair.random
  end

  def process_result_xdr(result = RESULT)
    entries = result.map do |key, value|
      Xdr.int32(Xdr::SCV_SYMBOL) + Xdr.string(key.to_s) + Xdr.sc_u32(value)
    end
    Xdr.encode64(Xdr.int32(Xdr::SCV_MAP) + Xdr.uint32(1) + Xdr.uint32(entries.length) + entries.join)
  end

  def process_result_json(result = RESULT)
    { "map" => result.map { |key, value| { "key" => { "symbol" => key.to_s }, "val" => { "u32" => value } } } }
  end

  # The bytes SorobanTransactionData ends with: some resources, then the int64 resource fee.
  def soroban_data(resource_fee)
    Xdr.encode64("resources-placeholder".b + Xdr.int64(resource_fee))
  end

  def rpc(overrides = {})
    FakeRpc.new({
      "getLedgerEntries" => { "entries" => [{ "dataJson" => { "account" => { "seq_num" => "41" } } }] },
      "simulateTransaction" => {
        "results" => [{ "xdr" => process_result_xdr, "auth" => [Xdr.encode64("auth-entry-placeholder")] }],
        "transactionData" => soroban_data(1000),
        "minResourceFee" => "1000"
      },
      "sendTransaction" => { "status" => "PENDING" },
      "getTransaction" => {
        "status" => "SUCCESS",
        "ledger" => 101,
        "resultMetaJson" => { "v4" => { "soroban_meta" => { "return_value" => process_result_json } } }
      }
    }.merge(overrides))
  end

  def assert_error(code)
    error = assert_raises(SubscriptionError) { yield }
    assert_equal code, error.code
    error
  end

  # Splits a TransactionEnvelope with one signature into transaction bytes and the signature.
  def unwrap_envelope(base64)
    bytes = Xdr.decode64(base64)
    [bytes[4...-(4 + 4 + 4 + 64)], bytes[-64..]]
  end

  def test_simulate_calls_process_on_the_contract_and_returns_the_result_without_sending
    fake = rpc
    result = Subscription.process(@merchant.seed, "7", 20, 10, mode: :simulate, faraday: fake)

    assert_equal RESULT, result
    envelope = Xdr.decode64(fake.calls("simulateTransaction").first.dig("params", "transaction"))
    assert_includes envelope, Xdr.decode_contract_address(CONTRACT)
    assert_includes envelope, Xdr.string("process")
    assert_includes envelope, Xdr.sc_account_address(@merchant.raw_public_key) + Xdr.sc_u64(7) + Xdr.sc_u32(20) + Xdr.sc_u32(10)
    assert_includes envelope, Xdr.int64(42) # account sequence 41 + 1
    assert_empty fake.calls("sendTransaction")
  end

  def test_submit_signs_with_the_merchant_key_adds_fee_headroom_and_returns_hash_ledger_and_result
    fake = rpc
    result = Subscription.process(@merchant.seed, 7, 0, 20, faraday: fake)

    transaction, signature = unwrap_envelope(fake.calls("sendTransaction").first.dig("params", "transaction"))
    tx_hash = Xdr.transaction_hash("Pi Testnet", transaction)
    assert_equal({ txid: tx_hash.unpack1("H*"), ledger: 101, result: RESULT }, result)
    assert @merchant.verify(signature, tx_hash)
    # fee: 100000 inclusion + 1000 simulated resource fee * 150%; the soroban data carries the same 1500
    assert_includes transaction, Xdr.uint32(101_500) + Xdr.int64(42)
    assert transaction.end_with?(Xdr.int32(1) + "resources-placeholder".b + Xdr.int64(1500))
    assert_includes transaction, Xdr.uint32(1) + "auth-entry-placeholder"
    assert_equal [{ "hash" => tx_hash.unpack1("H*"), "xdrFormat" => "json" }], fake.calls("getTransaction").map { |r| r["params"] }
  end

  def test_rejects_invalid_arguments_before_calling_the_rpc_server
    fake = rpc
    {
      invalid_merchant_secret: -> { Subscription.process(@merchant.address, 7, 0, 20, faraday: fake) },
      invalid_service_id: -> { Subscription.process(@merchant.seed, -1, 0, 20, faraday: fake) },
      invalid_offset: -> { Subscription.process(@merchant.seed, 7, 1.5, 20, faraday: fake) },
      invalid_limit: -> { Subscription.process(@merchant.seed, 7, 0, 2**32, faraday: fake) },
      invalid_mode: -> { Subscription.process(@merchant.seed, 7, 0, 20, mode: :sign, faraday: fake) },
      invalid_timeout: -> { Subscription.process(@merchant.seed, 7, 0, 20, timeout_seconds: 0, faraday: fake) },
      invalid_contract_address: -> { Subscription.process(@merchant.seed, 7, 0, 20, contract_address: @merchant.address, faraday: fake) }
    }.each do |code, call|
      assert_error(code) { call.call }
    end
    assert_error(:invalid_service_id) { Subscription.process(@merchant.seed, "", 0, 20, faraday: fake) }
    assert_error(:invalid_service_id) { Subscription.process(@merchant.seed, (2**64).to_s, 0, 20, faraday: fake) }
    assert_empty fake.requests
  end

  def test_reports_a_missing_merchant_account
    assert_error(:account_not_found) do
      Subscription.process(@merchant.seed, 7, 0, 20, faraday: rpc("getLedgerEntries" => { "entries" => [] }))
    end
  end

  def test_names_the_contract_error_when_the_simulation_fails
    fake = rpc("simulateTransaction" => { "error" => "HostError: Error(Contract, #9)" })
    error = assert_error(:simulation_failed) { Subscription.process(@merchant.seed, 7, 0, 20, faraday: fake) }
    assert_equal "NotServiceOwner", error.contract_error_name
    assert_equal 9, error.contract_error_code
    assert_empty fake.calls("sendTransaction")
  end

  def test_reports_a_refused_send_with_its_result_code
    refused = Xdr.encode64(Xdr.int64(100) + Xdr.int32(-7) + Xdr.int32(0))
    fake = rpc("sendTransaction" => { "status" => "ERROR", "errorResultXdr" => refused })
    error = assert_error(:transaction_rejected) { Subscription.process(@merchant.seed, 7, 0, 20, faraday: fake) }
    assert_equal "txInsufficientBalance", error.detail
    assert_empty fake.calls("getTransaction")
  end

  def test_reports_a_failed_transaction_with_its_hash
    fake = rpc("getTransaction" => { "status" => "FAILED", "resultJson" => { "result" => { "tx_failed" => [] } } })
    error = assert_error(:transaction_failed) { Subscription.process(@merchant.seed, 7, 0, 20, faraday: fake) }
    assert_equal "tx_failed", error.detail
    refute_nil error.txid
  end

  def test_keeps_the_hash_when_the_outcome_is_unknown_so_the_caller_can_look_it_up
    Subscription::Rpc.any_instance.stubs(:sleep)
    Time.stubs(:now).returns(Time.at(1_000), Time.at(1_000), Time.at(2_000))
    fake = rpc("getTransaction" => { "status" => "NOT_FOUND" })
    error = assert_error(:transaction_not_confirmed) { Subscription.process(@merchant.seed, 7, 0, 20, faraday: fake) }
    transaction, = unwrap_envelope(fake.calls("sendTransaction").first.dig("params", "transaction"))
    assert_equal Xdr.transaction_hash("Pi Testnet", transaction).unpack1("H*"), error.txid
  end

  def test_keeps_the_hash_when_the_send_request_itself_fails
    failing = rpc
    def failing.post(url, body, headers)
      raise Faraday::ConnectionFailed, "connection reset" if JSON.parse(body)["method"] == "sendTransaction"

      super
    end
    error = assert_error(:transaction_not_confirmed) { Subscription.process(@merchant.seed, 7, 0, 20, faraday: failing) }
    refute_nil error.txid
  end
end

class SubscriptionXdrTest < Minitest::Test
  def test_decodes_a_contract_address_and_refuses_anything_else
    assert_equal 32, Xdr.decode_contract_address("CCUF75B6W3HRJTJD6O7OXNI72HGJ7DERZ5MUNOMFMSK23ME5GUIKPFYV").bytesize
    assert_nil Xdr.decode_contract_address("CCUF75B6W3HRJTJD6O7OXNI72HGJ7DERZ5MUNOMFMSK23ME5GUIKPFYW") # bad checksum
    assert_nil Xdr.decode_contract_address(Stellar::KeyPair.random.address)
    assert_nil Xdr.decode_contract_address(nil)
  end

  def test_reads_transaction_result_codes
    assert_equal "txBadSeq", Xdr.transaction_result_code(Xdr.int64(0) + Xdr.int32(-5))
    assert_nil Xdr.transaction_result_code("short")
  end
end
