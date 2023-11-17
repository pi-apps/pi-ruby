require 'minitest/autorun'
require_relative '../lib/pinetwork'

class A2UConcurrencyTest < Minitest::Test
  def test_concurrent_create_payment
    total_threads = 10000
    api_key = "api-key"
    wallet_private_key = "SC2L62EYF7LYF43L4OOSKUKDESRAFJZW3UW6RFZ57UY25VAMHTL2BFER"

    threads = []
    
    faraday_stub = Minitest::Mock.new
    pi = PiNetwork.new(api_key: api_key, wallet_private_key: wallet_private_key, faraday: faraday_stub)

    total_threads.times do
      threads << Thread.new do
        faraday_response = Faraday::Response.new(
          status: 200,
          body: {identifier: SecureRandom.alphanumeric(12)}.to_json,
          response_headers: {}
        )
        faraday_stub.expect(:post, faraday_response) do |url|
          url == "https://api.minepi.com/v2/payments"
        end
        
        payment_data = { amount: 1, memo: "test", metadata: {"info": "test"}, uid: "test-uid" }
        payment_id = pi.create_payment(payment_data)
      end
    end
    threads.each(&:join)

    open_payments_after = pi.instance_variable_get(:@open_payments)
    assert_equal(total_threads, open_payments_after.values.uniq.count, "open_payments got corrupted!")
  end
end