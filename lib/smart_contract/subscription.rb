require 'faraday'
require 'json'
require 'stellar-sdk'
require_relative '../errors'
require_relative 'xdr'

class PiNetwork
  module SmartContract
    # Server-side counterpart of the client SDK's Pi.SmartContract.Subscription.
    module Subscription
      RPC_URL = "https://rpc.testnet.minepi.com".freeze
      NETWORK_PASSPHRASE = "Pi Testnet".freeze
      CONTRACT_ADDRESS = "CCUF75B6W3HRJTJD6O7OXNI72HGJ7DERZ5MUNOMFMSK23ME5GUIKPFYV".freeze
      TX_TIMEOUT_SECONDS = 180
      # Inclusion fee in stroops (0.01 Pi), the same as the client SDK's smart-contract calls.
      INCLUSION_FEE = 100_000
      # Headroom on the simulated resource fee. process() extends the TTL of every entry it touches, and the rent
      # for that can grow between simulation and inclusion; a too-tight fee fails with insufficient_refundable_fee.
      # The unused refundable part is returned to the merchant.
      RESOURCE_FEE_MARGIN_PERCENT = 150
      POLL_INTERVAL_SECONDS = 1
      U32_MAX = 0xffff_ffff
      U64_MAX = 2**64 - 1
      MODES = %i[simulate submit].freeze

      # Contract error codes of the subscription contract (PiCoreTeam/pi-smartcontracts, contracts/subscription).
      CONTRACT_ERRORS = {
        1 => "InvalidPrice", 2 => "InvalidPeriod", 3 => "AlreadySubscribed", 4 => "SubscriptionNotFound",
        5 => "ServiceNotFound", 6 => "Unauthorized", 7 => "AlreadyCancelled", 8 => "TimestampOverflow",
        9 => "NotServiceOwner", 10 => "InvalidServiceName", 11 => "SubscriptionExpired", 12 => "ServiceNotActive",
        13 => "NoAdminProposed", 14 => "NotProposedAdmin", 15 => "NoUpgradeProposed",
        16 => "UpgradeTimelockNotElapsed", 17 => "UpgradeAlreadyPending", 18 => "ServiceShutdown"
      }.freeze

      SubscriptionError = PiNetwork::Errors::SubscriptionError

      # Runs the subscription contract's process() for a service, signed with the merchant's own secret seed on the
      # server, and sends it straight to the Soroban RPC server: no Pi Browser, no wallet passphrase screen.
      #
      # process() charges every due, auto-renewing subscription in [offset, offset + limit) of the service's
      # subscription list. Read the merchant secret from your server's environment; never send it to a client.
      #
      # mode: :submit (default) signs, sends, waits and returns { txid:, ledger:, result: }.
      # mode: :simulate returns the result the call would produce, without signing or sending.
      # result is { charged:, failed:, skipped:, total: }.
      def self.process(merchant_secret, service_id, offset, limit,
                       mode: :submit,
                       rpc_url: RPC_URL,
                       network_passphrase: NETWORK_PASSPHRASE,
                       contract_address: CONTRACT_ADDRESS,
                       timeout_seconds: TX_TIMEOUT_SECONDS,
                       faraday: Faraday.new)
        keypair = merchant_keypair(merchant_secret)
        service_id_value = to_uint(service_id, U64_MAX, :invalid_service_id)
        offset_value = to_uint(offset, U32_MAX, :invalid_offset)
        limit_value = to_uint(limit, U32_MAX, :invalid_limit)
        mode = mode.to_sym if mode.is_a?(String)
        raise SubscriptionError.new(:invalid_mode) unless MODES.include?(mode)
        unless timeout_seconds.is_a?(Integer) && timeout_seconds.positive?
          raise SubscriptionError.new(:invalid_timeout)
        end
        contract_id = Xdr.decode_contract_address(contract_address)
        raise SubscriptionError.new(:invalid_contract_address) unless contract_id

        rpc = Rpc.new(rpc_url, faraday)
        source = keypair.raw_public_key
        sequence = rpc.account_sequence(source) + 1
        min_time = 0
        max_time = Time.now.to_i + timeout_seconds
        args = [
          Xdr.sc_account_address(source),
          Xdr.sc_u64(service_id_value),
          Xdr.sc_u32(offset_value),
          Xdr.sc_u32(limit_value)
        ]
        build = lambda do |fee:, auth: [], soroban_data: nil|
          Xdr.transaction(
            source_raw_public_key: source, fee: fee, sequence: sequence, min_time: min_time, max_time: max_time,
            operation: Xdr.invoke_contract_operation(contract_id, "process", args, auth), soroban_data: soroban_data
          )
        end

        unsigned = build.call(fee: INCLUSION_FEE)
        simulation = rpc.simulate(Xdr.envelope(unsigned, Xdr.transaction_hash(network_passphrase, unsigned)))
        result = Xdr.read_symbol_u32_map(Xdr.decode64(simulation["results"][0]["xdr"]))
        result = process_result(result)
        return result if mode == :simulate

        resource_fee = Integer(simulation["minResourceFee"]) * RESOURCE_FEE_MARGIN_PERCENT / 100
        fee = INCLUSION_FEE + resource_fee
        raise SubscriptionError.new(:fee_too_high, detail: "#{fee} stroops") if fee > U32_MAX

        soroban_data = Xdr.with_resource_fee(Xdr.decode64(simulation["transactionData"]), resource_fee)
        auth = Array(simulation["results"][0]["auth"]).map { |entry| Xdr.decode64(entry) }
        signed = build.call(fee: fee, auth: auth, soroban_data: soroban_data)
        tx_hash_bytes = Xdr.transaction_hash(network_passphrase, signed)
        txid = tx_hash_bytes.unpack1("H*")

        rpc.send_transaction(Xdr.envelope(signed, tx_hash_bytes, [keypair]), txid)
        # Poll past the transaction's validity window: once it has passed, a transaction that is still not found
        # can no longer be included.
        outcome = rpc.wait_for_transaction(txid, deadline: max_time + 10)

        { txid: txid, ledger: outcome[:ledger], result: process_result(outcome[:return_value]) }
      end

      def self.merchant_keypair(merchant_secret)
        Stellar::Util::StrKey.check_decode(:seed, merchant_secret)
        Stellar::KeyPair.from_seed(merchant_secret)
      rescue StandardError
        raise SubscriptionError.new(:invalid_merchant_secret)
      end
      private_class_method :merchant_keypair

      def self.to_uint(value, max, code)
        parsed = if value.is_a?(Integer) then value
                 elsif value.is_a?(String) && value.match?(/\A\d+\z/) then Integer(value, 10)
                 end
        raise SubscriptionError.new(code) if parsed.nil? || parsed.negative? || parsed > max

        parsed
      end
      private_class_method :to_uint

      def self.process_result(map)
        { charged: map.fetch("charged"), failed: map.fetch("failed"),
          skipped: map.fetch("skipped"), total: map.fetch("total") }
      rescue KeyError, NoMethodError
        raise SubscriptionError.new(:unexpected_response, detail: "Not a ProcessResult: #{map.inspect}")
      end
      private_class_method :process_result

      # Reads "Error(Contract, #N)" out of an RPC error text.
      def self.contract_error(text)
        match = /Error\(Contract, #(\d+)\)/.match(text.to_s)
        return {} unless match

        code = Integer(match[1])
        { contract_error_code: code, contract_error_name: CONTRACT_ERRORS.fetch(code, "UnknownError") }
      end

      # Soroban JSON-RPC calls. Results are requested as JSON where the SDK reads them, so no XDR decoding is needed.
      class Rpc
        def initialize(url, faraday)
          @url = url
          @faraday = faraday
        end

        def account_sequence(raw_public_key)
          key = Xdr.encode64(Xdr.account_ledger_key(raw_public_key))
          result = call("getLedgerEntries", { keys: [key], xdrFormat: "json" })
          entry = Array(result["entries"]).first
          raise SubscriptionError.new(:account_not_found) unless entry

          Integer(entry.dig("dataJson", "account", "seq_num"))
        end

        def simulate(envelope)
          result = call("simulateTransaction", { transaction: Xdr.encode64(envelope) })
          if result["error"]
            raise SubscriptionError.new(:simulation_failed, detail: result["error"],
                                                            **Subscription.contract_error(result["error"]))
          end
          raise SubscriptionError.new(:state_archived) if result["restorePreamble"]
          unless result.dig("results", 0, "xdr")
            raise SubscriptionError.new(:simulation_failed, detail: "The simulation returned no result.")
          end

          result
        end

        def send_transaction(envelope, txid)
          # Requested in base64: with xdrFormat "json", Pi's RPC server fails to encode a refused transaction's
          # diagnostic events and answers with an internal error instead of the refusal.
          result = begin
            call("sendTransaction", { transaction: Xdr.encode64(envelope) })
          rescue SubscriptionError => e
            # The request may have reached the server: the transaction can still land under this hash.
            raise SubscriptionError.new(:transaction_not_confirmed, txid: txid, detail: e.detail || e.message)
          end
          status = result["status"]
          return if %w[PENDING DUPLICATE].include?(status)

          code = result["errorResultXdr"] && Xdr.transaction_result_code(Xdr.decode64(result["errorResultXdr"]))
          raise SubscriptionError.new(:transaction_rejected, txid: txid, detail: code || status)
        end

        def wait_for_transaction(txid, deadline:)
          last_detail = nil
          loop do
            begin
              result = call("getTransaction", { hash: txid, xdrFormat: "json" })
              case result["status"]
              when "SUCCESS"
                meta = result["resultMetaJson"].values.first
                return { ledger: result["ledger"], return_value: json_symbol_u32_map(meta.dig("soroban_meta", "return_value")) }
              when "FAILED"
                code = result.dig("resultJson", "result")
                code = code.keys.first if code.is_a?(Hash)
                raise SubscriptionError.new(:transaction_failed, txid: txid, detail: code.to_s)
              else
                last_detail = result["status"]
              end
            rescue SubscriptionError => e
              raise e unless e.code == :rpc_error

              last_detail = e.detail
            end
            if Time.now.to_i > deadline
              raise SubscriptionError.new(:transaction_not_confirmed, txid: txid, detail: last_detail)
            end

            sleep POLL_INTERVAL_SECONDS
          end
        end

        private

        # { "map": [{ "key": { "symbol": "charged" }, "val": { "u32": 0 } }, ...] } -> { "charged" => 0, ... }
        def json_symbol_u32_map(value)
          Hash[Array(value && value["map"]).map { |entry| [entry.dig("key", "symbol"), entry.dig("val", "u32")] }]
        end

        def call(method, params)
          response = @faraday.post(@url, { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json,
                                   "Content-Type" => "application/json")
          unless response.status == 200
            raise SubscriptionError.new(:rpc_error, detail: "HTTP #{response.status} from #{method}")
          end

          body = JSON.parse(response.body)
          raise SubscriptionError.new(:rpc_error, detail: body["error"].to_json) if body["error"]

          body["result"]
        rescue Faraday::Error, JSON::ParserError => e
          raise SubscriptionError.new(:rpc_error, detail: "#{method}: #{e.message}")
        end
      end
    end
  end
end
