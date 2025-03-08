require 'minitest/autorun'
require 'mocha/minitest'
require 'ostruct'
require_relative '../lib/pinetwork'
require_relative '../lib/errors'

def set_tx_submission_timers(timeout, retry_delay)
  # Disable warnings that will clog up the terminal
  $VERBOSE = nil

  PiNetwork.const_set(:TX_SUBMISSION_TIMEOUT_SECONDS, timeout)
  PiNetwork.const_set(:TX_RETRY_DELAY_SECONDS, retry_delay)

  $VERBOSE = true
end

def json_parse_to_struct(hash)
  JSON.parse(hash.to_json, { object_class: OpenStruct })
end

def setup_horizon_mock(submit_transaction_response_hashes)
  horizon_mock = mock()

  account_info_response = OpenStruct.new(sequence: 1) # Used during build_a2u_transaction
  horizon_mock.expects(:account_info).returns(account_info_response).at_least_once

  submit_transaction_responses = submit_transaction_response_hashes.map { |h| json_parse_to_struct(h) }
  horizon_mock.expects(:submit_transaction).returns(*submit_transaction_responses).at_least_once

  horizon_mock
end

class TransactionSubmissionTest < Minitest::Test
  attr_reader :pi, :account, :payment, :txid

  def setup
    # Adjust submission timeout values to speed the test up
    set_tx_submission_timers(5, 1)

    # Then set up the necessary data
    api_key = "api-key"
    wallet_private_key = Stellar::KeyPair.random.seed
    @pi = PiNetwork.new(api_key: api_key, wallet_private_key: wallet_private_key)

    from_wallet_keypair = Stellar::KeyPair.from_seed(wallet_private_key)
    from_address = from_wallet_keypair.public_key
    @account = OpenStruct.new(address: from_address, keypair: from_wallet_keypair)

    payment_id = "1234abcd"
    @payment = {
      "identifier" => payment_id,
      "network" => "Pi Network",
      "amount" => 3.14,
      "from_address" => account.address,
      "to_address" => Stellar::KeyPair.random.address
    }

    @txid = "01234abcde"

    pi.stubs(:get_payment).returns(payment) # Avoid API call to platform BE
    pi.stubs(:account).returns(account)
  end

  def teardown
    set_tx_submission_timers(30, 5)
  end

  def test_submission_timeout
    # Hard-coding enough responses to time out based on current parameters for set_tx_submission_timers(5, 1)
    submit_transaction_responses = [
      { _response: { body: { title: "Historical DB Is Too Stale" }, status: 503 } }, # 0 sec
      { _response: { body: { title: "Historical DB Is Too Stale" }, status: 503 } }, # 1
      { _response: { body: { title: "Historical DB Is Too Stale" }, status: 503 } }, # 2
      { _response: { body: { title: "Historical DB Is Too Stale" }, status: 503 } }, # 3
      { _response: { body: { title: "Historical DB Is Too Stale" }, status: 503 } }, # 4
      { _response: { body: { title: "Historical DB Is Too Stale" }, status: 503 } }, # 5; At timeout limit, raise here
      { _response: { body: { title: "Historical DB Is Too Stale" }, status: 503 } }, # Just to avoid possible race condition effects
    ]
    horizon_mock = setup_horizon_mock(submit_transaction_responses)

    pi.stubs(:client).returns(horizon_mock)

    error = assert_raises(PiNetwork::Errors::TxSubmissionError) { pi.submit_payment(payment["identifier"]) }

    assert_equal("tx_too_late", error.tx_error_code, "Raised error has wrong tx error code")
    assert_nil(error.op_error_codes, "Raised error has unexpected op error codes")
  end

  def test_server_error_response
    submit_transaction_responses = [
      { _response: { body: { title: "Historical DB Is Too Stale" }, status: 503 } }, # Server error response first
      { _response: { body: { "id": txid }, status: 200 } } # Then success on retry
    ]
    horizon_mock = setup_horizon_mock(submit_transaction_responses)

    pi.stubs(:client).returns(horizon_mock)

    assert_equal(txid, pi.submit_payment(payment["identifier"]), "Returned txid does not match expected value")
  end

  def test_user_error_response
    submit_transaction_responses = [
      {
        _response: {
          body: {
            title: "Transaction Failed",
            extras: {
              result_codes: {
                transaction: "tx_failed",
                operations: ["op_no_source_account"]
              }
            }
          },
          status: 400
        }
      }
    ]
    horizon_mock = setup_horizon_mock(submit_transaction_responses)

    pi.stubs(:client).returns(horizon_mock)

    error = assert_raises(PiNetwork::Errors::TxSubmissionError) { pi.submit_payment(payment["identifier"]) }

    assert_equal("tx_failed", error.tx_error_code, "Raised error has wrong tx error code")
    assert_equal(["op_no_source_account"], error.op_error_codes, "Raised error has wrong op error codes")
  end

  def test_success_response
    submit_transaction_responses = [{ _response: { body: { "id": txid }, status: 200 } }]
    horizon_mock = setup_horizon_mock(submit_transaction_responses)

    pi.stubs(:client).returns(horizon_mock)

    assert_equal(txid, pi.submit_payment(payment["identifier"]), "Returned txid does not match expected value")
  end
end
