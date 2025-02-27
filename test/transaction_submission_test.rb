require 'minitest/autorun'
require 'ostruct'
require 'json'
require 'stellar-sdk'
require_relative '../lib/pinetwork'

class TransactionSubmissionTest < Minitest::Test
  # test_payment_submission
  # test_payment_400_response
  # test_payment_500_response # e.g. 503
  # test_payment_retry

  def test_transaction_submission
    api_key = "api-key"
    wallet_private_key = "SC2L62EYF7LYF43L4OOSKUKDESRAFJZW3UW6RFZ57UY25VAMHTL2BFER"
    pi = PiNetwork.new(api_key: api_key, wallet_private_key: wallet_private_key)

    from_wallet_keypair = Stellar::KeyPair.from_seed(wallet_private_key)
    from_address = from_wallet_keypair.public_key

    payment_id = "1234abcd"
    payment = {
      "identifier" => payment_id,
      "network" => "Pi Network",
      "amount" => 3.14,
      "from_address" => from_address,
      "to_address" => "GDCTIXFMVAHYKHRH6SN5PEH5432426NTV2LYFHRP4BBGN5SR4GPCPT2A"
    }

    txid = "01234abcde"
    horizon_mock = Minitest::Mock.new
    account_info_response = OpenStruct.new(sequence: 1) # Used during build_a2u_transaction
    submit_transaction_response = JSON.parse(
      { _response: { body: { "id": txid } } }.to_json,
      { object_class: OpenStruct }
    )
    horizon_mock.expect(:account_info, account_info_response, [payment["from_address"]])
    horizon_mock.expect(:submit_transaction, submit_transaction_response) do |args|
      args[:tx_envelope] != nil
    end

    pi.stub(:get_payment, payment) do # Avoid API call to MA BE
      pi.stub(:client, horizon_mock) do
        pi.stub(:account, OpenStruct.new(address: from_address, keypair: from_wallet_keypair)) do
          assert_equal(pi.submit_payment(payment_id), txid, "Returned txid does not match expected value")

          horizon_mock.verify
        end
      end
    end
  end
end
