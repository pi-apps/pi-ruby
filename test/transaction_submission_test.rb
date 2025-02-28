require 'minitest/autorun'
require 'mocha/minitest'
require 'ostruct'
require 'json'
require 'stellar-sdk'
require_relative '../lib/pinetwork'
require_relative '../lib/errors'

def set_tx_submission_timers(timeout, retry_delay)
  # Disable warnings that will clog up the terminal
  $VERBOSE = nil

  PiNetwork.const_set(:TX_SUBMISSION_TIMEOUT_SECONDS, timeout)
  PiNetwork.const_set(:TX_RETRY_DELAY_SECONDS, retry_delay)

  $VERBOSE = true
end

def setup_horizon_mock(submit_transaction_response_hash)
  horizon_mock = mock()
  account_info_response = OpenStruct.new(sequence: 1) # Used during build_a2u_transaction
  submit_transaction_response = JSON.parse(submit_transaction_response_hash.to_json, { object_class: OpenStruct })

  horizon_mock.expects(:account_info).returns(account_info_response).at_least_once
  horizon_mock.expects(:submit_transaction).returns(submit_transaction_response).at_least_once

  horizon_mock
end

class TransactionSubmissionTest < Minitest::Test
  attr_reader :pi, :account, :payment, :txid

  # TODO:
  # test_payment_400_response
  # test_payment_timeout

  def setup
    # Adjust submission timeout values to speed the test up
    set_tx_submission_timers(5, 1)

    # Then set up the necessary data
    api_key = "api-key"
    wallet_private_key = "SC2L62EYF7LYF43L4OOSKUKDESRAFJZW3UW6RFZ57UY25VAMHTL2BFER"
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
      "to_address" => "GDCTIXFMVAHYKHRH6SN5PEH5432426NTV2LYFHRP4BBGN5SR4GPCPT2A"
    }

    @txid = "01234abcde"

    pi.stubs(:get_payment).returns(payment) # Avoid API call to platform BE
    pi.stubs(:account).returns(account)
  end

  def teardown
    set_tx_submission_timers(30, 5)
  end

  def test_user_error_response
    submit_transaction_response = { _response: { body: { title: "Transaction Failed" }, status: 400 } }
    horizon_mock = setup_horizon_mock(submit_transaction_response)

    pi.stubs(:client).returns(horizon_mock)

    assert_raises(StandardError) { pi.submit_payment(payment["identifier"]) }
  end

  def test_success_response
    submit_transaction_response = { _response: { body: { "id": txid }, status: 200 } }
    horizon_mock = setup_horizon_mock(submit_transaction_response)

    pi.stubs(:client).returns(horizon_mock)

    assert_equal(pi.submit_payment(payment["identifier"]), txid, "Returned txid does not match expected value")
  end
end
