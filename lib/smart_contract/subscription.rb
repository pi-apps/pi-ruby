require 'faraday'
require 'json'
require 'uri'
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
      # Per RPC request, so one request that never answers can't hold process past its deadline for long.
      REQUEST_TIMEOUT_SECONDS = 30
      U32_MAX = 0xffff_ffff
      U64_MAX = 2**64 - 1
      # The account sequence is an int64, and the transaction uses the next one.
      SEQUENCE_MAX = 2**63 - 2
      MODES = %i[simulate submit].freeze

      # Contract error codes of the subscription contract as deployed on Pi Testnet (v1, CCUF75B6...); any other code
      # is reported as UnknownError. Verified against the deployed wasm; after a contract upgrade, compare with
      # `stellar contract info interface --id <contract> --network pi-testnet` (enum ContractError).
      CONTRACT_ERRORS = {
        1 => "InvalidPrice", 2 => "InvalidPeriod", 3 => "AlreadySubscribed", 4 => "SubscriptionNotFound",
        5 => "ServiceNotFound", 6 => "Unauthorized", 7 => "AlreadyCancelled", 8 => "TimestampOverflow",
        9 => "NotServiceOwner", 10 => "InvalidServiceName", 11 => "SubscriptionExpired", 12 => "ServiceNotActive",
        13 => "NoAdminProposed", 14 => "NotProposedAdmin", 15 => "NoUpgradeProposed",
        16 => "UpgradeTimelockNotElapsed", 17 => "UpgradeAlreadyPending"
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
      #
      # The call uses the merchant account's next sequence number. If the same wallet also sends other transactions
      # (for example A2U payments with PiNetwork created from the same seed), don't run them at the same time as
      # process: two transactions built on the same sequence number can't both land. When process loses, it fails
      # with :transaction_rejected (detail "txBadSeq") if the other transaction had already landed when it was sent,
      # or the RPC server drops it after accepting it and it ends in :transaction_not_confirmed (detail "NOT_FOUND")
      # once its validity window has passed. Either way that batch did not run and can be run again. Run them one
      # after the other, or use separate wallets.
      def self.process(merchant_secret, service_id, offset, limit,
                       mode: :submit,
                       rpc_url: RPC_URL,
                       network_passphrase: NETWORK_PASSPHRASE,
                       contract_address: CONTRACT_ADDRESS,
                       timeout_seconds: TX_TIMEOUT_SECONDS,
                       faraday: Faraday.new(request: { timeout: REQUEST_TIMEOUT_SECONDS,
                                                       open_timeout: REQUEST_TIMEOUT_SECONDS }))
        # nil means the default, as an omitted option does (and as null does in the Node.js package).
        mode = :submit if mode.nil?
        rpc_url ||= RPC_URL
        network_passphrase ||= NETWORK_PASSPHRASE
        contract_address ||= CONTRACT_ADDRESS
        timeout_seconds ||= TX_TIMEOUT_SECONDS
        keypair = merchant_keypair(merchant_secret)
        service_id_value = to_uint(service_id, U64_MAX, :invalid_service_id)
        offset_value = to_uint(offset, U32_MAX, :invalid_offset)
        limit_value = to_uint(limit, U32_MAX, :invalid_limit)
        mode = mode.to_sym if mode.is_a?(String) && mode.valid_encoding?
        raise SubscriptionError.new(:invalid_mode) unless MODES.include?(mode)
        # Bounded so the transaction's time bounds (u64) can't wrap around.
        unless timeout_seconds.is_a?(Integer) && timeout_seconds.positive? && timeout_seconds <= U32_MAX
          raise SubscriptionError.new(:invalid_timeout)
        end
        rpc_uri = http_uri(rpc_url)
        raise SubscriptionError.new(:invalid_rpc_url) unless rpc_uri
        unless network_passphrase.is_a?(String) && !network_passphrase.empty?
          raise SubscriptionError.new(:invalid_network_passphrase)
        end
        contract_id = Xdr.decode_contract_address(contract_address)
        raise SubscriptionError.new(:invalid_contract_address) unless contract_id

        rpc = Rpc.new(rpc_uri.to_s, faraday)
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
        result = process_result(simulation_result_map(simulation))
        return result if mode == :simulate

        resource_fee, soroban_data, auth = read_simulation(simulation)
        fee = INCLUSION_FEE + resource_fee
        raise SubscriptionError.new(:fee_too_high, detail: "#{fee} stroops") if fee > U32_MAX

        signed = build.call(fee: fee, auth: auth, soroban_data: soroban_data)
        tx_hash_bytes = Xdr.transaction_hash(network_passphrase, signed)
        txid = tx_hash_bytes.unpack1("H*")

        rpc.send_transaction(Xdr.envelope(signed, tx_hash_bytes, [keypair]), txid)
        # Poll past the transaction's validity window: once it has passed, a transaction that is still not found
        # can no longer be included.
        outcome = rpc.wait_for_transaction(txid, deadline: max_time + 10)

        { txid: txid, ledger: outcome[:ledger], result: process_result(outcome[:return_value], txid: txid) }
      end

      def self.merchant_keypair(merchant_secret)
        Stellar::Util::StrKey.check_decode(:seed, merchant_secret)
        Stellar::KeyPair.from_seed(merchant_secret)
      rescue StandardError
        raise SubscriptionError.new(:invalid_merchant_secret)
      end
      private_class_method :merchant_keypair

      def self.to_uint(value, max, code)
        parse_uint(value, max) || raise(SubscriptionError.new(code))
      end
      private_class_method :to_uint

      # An Integer or a String of digits in 0..max, as an Integer; nil for anything else (including Floats and
      # negative numbers). Used for arguments and for the numbers read from the RPC server.
      def self.parse_uint(value, max)
        parsed = if value.is_a?(Integer) then value
                 elsif value.is_a?(String) && value.valid_encoding? && value.match?(/\A\d+\z/) then Integer(value, 10)
                 end
        parsed if parsed && parsed >= 0 && parsed <= max
      end

      # An http(s) URI with a host (the scheme comes back lower-cased), or nil.
      def self.http_uri(value)
        return nil unless value.is_a?(String)

        uri = URI.parse(value)
        %w[http https].include?(uri.scheme) && !uri.host.to_s.empty? ? uri : nil
      rescue URI::InvalidURIError
        nil
      end
      private_class_method :http_uri

      # Every count is a u32, so anything else (a missing key, nil, a String, a negative number) is not a
      # ProcessResult. txid is set once the transaction has been sent, so an unreadable result still says which
      # transaction it was.
      def self.process_result(map, txid: nil)
        result = begin
          { charged: map.fetch("charged"), failed: map.fetch("failed"),
            skipped: map.fetch("skipped"), total: map.fetch("total") }
        rescue KeyError, NoMethodError
          nil
        end
        return result if result && result.values.all? { |value| value.is_a?(Integer) && value >= 0 && value <= U32_MAX }

        raise SubscriptionError.new(:unexpected_response, txid: txid, detail: "Not a ProcessResult: #{map.inspect}")
      end
      private_class_method :process_result

      def self.simulation_result_map(simulation)
        Xdr.read_symbol_u32_map(Xdr.decode64(simulation["results"][0]["xdr"]))
      rescue ArgumentError, NoMethodError => e
        raise SubscriptionError.new(:unexpected_response, detail: "Simulation result: #{e.message}")
      end
      private_class_method :simulation_result_map

      # [resource fee with headroom, soroban data carrying that fee, auth entries]
      def self.read_simulation(simulation)
        min_resource_fee = parse_uint(simulation["minResourceFee"], U64_MAX)
        raise ArgumentError, "minResourceFee is not a non-negative integer" unless min_resource_fee

        resource_fee = min_resource_fee * RESOURCE_FEE_MARGIN_PERCENT / 100
        # SorobanTransactionData ends with its int64 resourceFee, which is replaced; anything shorter isn't one.
        transaction_data = Xdr.decode64(simulation["transactionData"])
        raise ArgumentError, "transactionData is too short" unless transaction_data.bytesize > 8

        soroban_data = Xdr.with_resource_fee(transaction_data, resource_fee)
        auth = Array(simulation["results"][0]["auth"]).map { |entry| Xdr.decode64(entry) }
        [resource_fee, soroban_data, auth]
      rescue ArgumentError, TypeError, NoMethodError => e
        raise SubscriptionError.new(:unexpected_response, detail: "Simulation: #{e.message}")
      end
      private_class_method :read_simulation

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

          sequence = Subscription.parse_uint(entry.dig("dataJson", "account", "seq_num"), SEQUENCE_MAX)
          raise ArgumentError, "seq_num is not an int64 below the maximum" unless sequence

          sequence
        rescue ArgumentError, TypeError, NoMethodError => e
          raise SubscriptionError.new(:unexpected_response, detail: "Account sequence: #{e.message}")
        end

        def simulate(envelope)
          result = call("simulateTransaction", { transaction: Xdr.encode64(envelope) })
          if result["error"]
            raise SubscriptionError.new(:simulation_failed, detail: result["error"],
                                                            **Subscription.contract_error(result["error"]))
          end
          raise SubscriptionError.new(:state_archived) if result["restorePreamble"]
          results = result["results"]
          unless results.is_a?(Array) && results[0].is_a?(Hash) && results[0]["xdr"]
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
          # Only these two mean the transaction was not accepted. Anything else (PENDING, DUPLICATE, or a status
          # this SDK doesn't know) may still land, so it's polled for, as in the Node.js package.
          return unless %w[ERROR TRY_AGAIN_LATER].include?(status)

          raise SubscriptionError.new(:transaction_rejected, txid: txid,
                                                             detail: rejected_result_code(result) || status)
        end

        def wait_for_transaction(txid, deadline:)
          last_detail = nil
          loop do
            begin
              result = transaction_status(txid)
              case result["status"]
              when "SUCCESS"
                unless result.key?("resultMetaJson")
                  raise SubscriptionError.new(:unexpected_response, txid: txid,
                                                                    detail: "The transaction succeeded, but its result could only be read as base64.")
                end

                return { ledger: success_ledger(result, txid), return_value: success_return_value(result, txid) }
              when "FAILED"
                detail = result.key?("resultJson") ? failed_result_code(result) : result_code_from_xdr(result["resultXdr"])
                raise SubscriptionError.new(:transaction_failed, txid: txid, detail: detail)
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

        # getTransaction, read as JSON. If Pi's RPC server can't encode the answer as JSON (it can't for some, see
        # send_transaction), the status is read from the base64 answer instead, so a final FAILED or SUCCESS is never
        # mistaken for a failed request and polled until the deadline.
        def transaction_status(txid)
          call("getTransaction", { hash: txid, xdrFormat: "json" })
        rescue SubscriptionError => e
          raise e unless e.code == :rpc_error

          call("getTransaction", { hash: txid })
        end

        # The result code of a base64 TransactionResult (e.g. "txFailed"), or nil when it can't be read.
        def result_code_from_xdr(xdr)
          xdr.is_a?(String) ? Xdr.transaction_result_code(Xdr.decode64(xdr)) : nil
        rescue ArgumentError
          nil
        end

        # The ProcessResult a successful transaction returned. The transaction succeeded, so anything missing or
        # unreadable here is :unexpected_response, with the txid (as in the Node.js package).
        def success_return_value(result, txid)
          meta = result["resultMetaJson"]
          meta = meta.values.first if meta.is_a?(Hash)
          value = meta.dig("soroban_meta", "return_value") if meta.is_a?(Hash)
          unless value
            raise SubscriptionError.new(:unexpected_response, txid: txid,
                                                              detail: "The transaction succeeded but returned no value.")
          end

          json_symbol_u32_map(value)
        rescue TypeError, NoMethodError => e
          raise SubscriptionError.new(:unexpected_response, txid: txid, detail: "Transaction result: #{e.message}")
        end

        # The failed transaction's result code in the JS stellar-sdk's form used everywhere else (e.g. "txFailed"
        # for the JSON "tx_failed"), or nil when it can't be read.
        def failed_result_code(result)
          code = result.dig("resultJson", "result")
          code = code.keys.first if code.is_a?(Hash)
          return nil unless code.is_a?(String)

          words = code.split("_").reject(&:empty?)
          words.empty? ? nil : words[0] + words[1..-1].map(&:capitalize).join
        rescue TypeError
          nil
        end

        def success_ledger(result, txid)
          ledger = Subscription.parse_uint(result["ledger"], U32_MAX)
          return ledger if ledger

          raise SubscriptionError.new(:unexpected_response, txid: txid, detail: "Transaction ledger: #{result['ledger'].inspect}")
        end

        # The refused transaction's result code (e.g. "txBadSeq"), or nil when it can't be read.
        def rejected_result_code(result)
          result_code_from_xdr(result["errorResultXdr"])
        end

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

          # A connection with JSON response middleware has already parsed the body.
          body = response.body.is_a?(Hash) ? response.body : JSON.parse(response.body.to_s)
          raise SubscriptionError.new(:rpc_error, detail: "#{method}: not a JSON-RPC response") unless body.is_a?(Hash)
          raise SubscriptionError.new(:rpc_error, detail: body["error"].to_json) if body["error"]
          # Treated like a failed request: retried while polling, and after sending it means the outcome is unknown.
          raise SubscriptionError.new(:rpc_error, detail: "#{method}: no result object") unless body["result"].is_a?(Hash)

          body["result"]
        rescue Faraday::Error, JSON::ParserError => e
          raise SubscriptionError.new(:rpc_error, detail: "#{method}: #{e.message}")
        end
      end
    end
  end
end
