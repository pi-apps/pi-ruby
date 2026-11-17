require 'digest'
require 'stellar-sdk'

class PiNetwork
  module SmartContract
    # The few Stellar XDR shapes a Soroban contract call needs, written by hand: the stellar-sdk gem predates
    # Soroban, so it has none of them. Everything the RPC server returns is read as JSON (xdrFormat: "json") or
    # passed back as the opaque bytes the server produced, so only these encoders and one small reader exist.
    module Xdr
      CONTRACT_VERSION_BYTE = [2 << 3].pack("C") # Base32-encodes to 'C...'

      SCV_U32 = 3
      SCV_U64 = 5
      SCV_SYMBOL = 15
      SCV_MAP = 17
      SCV_ADDRESS = 18
      SC_ADDRESS_ACCOUNT = 0
      SC_ADDRESS_CONTRACT = 1
      OP_INVOKE_HOST_FUNCTION = 24
      HOST_FUNCTION_INVOKE_CONTRACT = 0
      PRECOND_TIME = 1
      MEMO_NONE = 0
      LEDGER_KEY_ACCOUNT = 0
      ENVELOPE_TYPE_TX = 2
      KEY_TYPE_ED25519 = 0

      module_function

      # Base64 without the base64 library, which Ruby 3.4 no longer loads by default.
      def encode64(bytes)
        [bytes].pack("m0")
      end

      def decode64(text)
        text.unpack1("m0")
      end

      def int32(value)
        [value].pack("l>")
      end

      def uint32(value)
        [value].pack("N")
      end

      def int64(value)
        [value].pack("q>")
      end

      def uint64(value)
        [value].pack("Q>")
      end

      def string(value)
        bytes = value.b
        uint32(bytes.bytesize) + bytes + ("\x00" * ((4 - bytes.bytesize % 4) % 4))
      end

      def opaque(bytes)
        uint32(bytes.bytesize) + bytes
      end

      # 32-byte contract ID from a 'C...' address, or nil when it isn't one.
      def decode_contract_address(address)
        return nil unless address.is_a?(String) && address.match?(/\AC[A-Z2-7]{55}\z/)

        decoded = Base32.decode(address)
        version, payload, check = decoded[0], decoded[1..32], decoded[33..34]
        return nil unless version == CONTRACT_VERSION_BYTE && payload&.bytesize == 32
        return nil unless check == Stellar::Util::StrKey.checksum(version + payload)
        return nil unless Base32.encode(decoded).tr("=", "") == address

        payload
      rescue StandardError
        nil
      end

      def public_key(raw_public_key)
        int32(KEY_TYPE_ED25519) + raw_public_key
      end

      def account_ledger_key(raw_public_key)
        int32(LEDGER_KEY_ACCOUNT) + public_key(raw_public_key)
      end

      def sc_account_address(raw_public_key)
        int32(SCV_ADDRESS) + int32(SC_ADDRESS_ACCOUNT) + public_key(raw_public_key)
      end

      def sc_u64(value)
        int32(SCV_U64) + uint64(value)
      end

      def sc_u32(value)
        int32(SCV_U32) + uint32(value)
      end

      # An invoke-contract operation. auth_entries are SorobanAuthorizationEntry bytes exactly as the
      # simulation returned them.
      def invoke_contract_operation(contract_id, function_name, args, auth_entries = [])
        uint32(0) + # no operation source account
          int32(OP_INVOKE_HOST_FUNCTION) +
          int32(HOST_FUNCTION_INVOKE_CONTRACT) +
          int32(SC_ADDRESS_CONTRACT) + contract_id +
          string(function_name) +
          uint32(args.length) + args.join +
          uint32(auth_entries.length) + auth_entries.join
      end

      # A Transaction with one operation and time bounds. soroban_data is SorobanTransactionData bytes, or nil.
      def transaction(source_raw_public_key:, fee:, sequence:, min_time:, max_time:, operation:, soroban_data: nil)
        int32(KEY_TYPE_ED25519) + source_raw_public_key +
          uint32(fee) +
          int64(sequence) +
          int32(PRECOND_TIME) + uint64(min_time) + uint64(max_time) +
          int32(MEMO_NONE) +
          uint32(1) + operation +
          (soroban_data ? int32(1) + soroban_data : int32(0))
      end

      def transaction_hash(network_passphrase, transaction_bytes)
        Digest::SHA256.digest(Digest::SHA256.digest(network_passphrase) + int32(ENVELOPE_TYPE_TX) + transaction_bytes)
      end

      # A TransactionEnvelope (v1) with the given keypairs' signatures over tx_hash.
      def envelope(transaction_bytes, tx_hash, keypairs = [])
        signatures = keypairs.map { |keypair| keypair.raw_public_key[-4, 4] + opaque(keypair.sign(tx_hash)) }
        int32(ENVELOPE_TYPE_TX) + transaction_bytes + uint32(signatures.length) + signatures.join
      end

      # SorobanTransactionData ends with its int64 resourceFee; returns the bytes with that fee replaced.
      def with_resource_fee(soroban_data, resource_fee)
        soroban_data[0...-8] + int64(resource_fee)
      end

      # TransactionResultCode names, as the JS stellar-sdk reports them.
      TRANSACTION_RESULT_CODES = {
        0 => "txSuccess", -1 => "txFailed", -2 => "txTooEarly", -3 => "txTooLate", -4 => "txMissingOperation",
        -5 => "txBadSeq", -6 => "txBadAuth", -7 => "txInsufficientBalance", -8 => "txNoAccount",
        -9 => "txInsufficientFee", -10 => "txBadAuthExtra", -11 => "txInternalError", -12 => "txNotSupported",
        -13 => "txFeeBumpInnerFailed", -14 => "txBadSponsorship", -15 => "txBadMinSeqAgeOrGap",
        -16 => "txMalformed", -17 => "txSorobanInvalid"
      }.freeze

      # The result code of a TransactionResult (int64 feeCharged, then the code).
      def transaction_result_code(bytes)
        reader = Reader.new(bytes)
        reader.int64
        code = reader.int32
        TRANSACTION_RESULT_CODES.fetch(code, "txUnknown(#{code})")
      rescue ArgumentError
        nil
      end

      # Reads an ScVal map whose keys are symbols and whose values are u32s, e.g. the contract's ProcessResult.
      def read_symbol_u32_map(bytes)
        reader = Reader.new(bytes)
        raise ArgumentError, "not a map" unless reader.int32 == SCV_MAP
        raise ArgumentError, "missing map" unless reader.uint32 == 1

        pairs = Array.new(reader.uint32) do
          raise ArgumentError, "map key is not a symbol" unless reader.int32 == SCV_SYMBOL
          key = reader.string
          raise ArgumentError, "map value is not a u32" unless reader.int32 == SCV_U32
          [key, reader.uint32]
        end
        Hash[pairs]
      end

      class Reader
        def initialize(bytes)
          @bytes = bytes.b
          @offset = 0
        end

        def int32
          take(4).unpack1("l>")
        end

        def uint32
          take(4).unpack1("N")
        end

        def int64
          take(8).unpack1("q>")
        end

        def string
          length = uint32
          value = take(length)
          take((4 - length % 4) % 4)
          value
        end

        private

        def take(count)
          raise ArgumentError, "unexpected end of XDR" if @offset + count > @bytes.bytesize
          chunk = @bytes[@offset, count]
          @offset += count
          chunk
        end
      end
    end
  end
end
