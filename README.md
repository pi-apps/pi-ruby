# Pi Ruby

This is a official Pi Network Ruby gem to integrate the Pi Network apps platform with a Ruby-based backend application.

## Install

1. Add the following line to your Gemfile:

```ruby
gem 'pinetwork'
```

2. Install the gem

```ruby
$ bundle install
```

## Versions

| Version | Ruby | What it includes | Install | Docs |
| --- | --- | --- | --- | --- |
| **0.2.0.pre.1** (prerelease) | same as 0.1.x | A2U payments, server-side subscription processing | `gem 'pinetwork', '0.2.0.pre.1'` | this README |
| **0.1.x** (current release) | same as before | A2U payments | `gem 'pinetwork'` | [0.1.5 README](https://github.com/pi-apps/pi-ruby/tree/v0.1.5) |

**Already using 0.1.x? Nothing changes for you.** Bundler and RubyGems never install a prerelease unless you ask for it by its exact version (or with `gem install --pre`), so `gem 'pinetwork'` and `bundle update` keep you on 0.1.x.

0.2.0 only adds `PiNetwork::SmartContract::Subscription`: there are no breaking changes, no new dependencies and no change to the payment methods. To try it, pin the prerelease in your Gemfile and run `bundle install`:

```ruby
gem 'pinetwork', '0.2.0.pre.1'
```

## SDK structure

```
pinetwork
├── PiNetwork                                    A2U payments
│     PiNetwork.new(api_key:, wallet_private_key:)
│     #create_payment(payment_data)
│     #submit_payment(payment_id)
│     #complete_payment(payment_id, txid)
│     #get_payment(payment_id)
│     #cancel_payment(payment_id)
│     #get_incomplete_server_payments
├── PiNetwork::SmartContract                     same path as the client SDK's Pi.SmartContract
│     └── Subscription
│           └── .process(merchant_secret, service_id, offset, limit, **options)
└── PiNetwork::Errors                            APIRequestError, PaymentNotFoundError, TxidAlreadyLinkedError,
                                                 TxSubmissionError, SubscriptionError
```

Smart-contract methods take their arguments in the same order as the client SDK and the Node.js package (`pi-backend`): who signs first, then IDs, then values or paging, then options last. The only difference from the client SDK is the first argument: it takes the merchant's address and asks the Pi Wallet to sign, while this gem takes the merchant's secret seed and signs on the server.

## Example

1. Initialize the SDK

```ruby
require 'pinetwork'

# DO NOT expose these values to public
api_key = "YOUR_PI_API_KEY"
wallet_private_seed = "S_YOUR_WALLET_PRIVATE_SEED" # starts with S

pi = PiNetwork.new(api_key: api_key, wallet_private_key: wallet_private_seed)
```

2. Create an A2U payment

Make sure to store your payment data in your database. Here's an example of how you could keep track of the data.
Consider this a database table example.

|    uid     | product_id  | amount |         memo         | payment_id | txid |
| :--------: | :---------: | :----: | :------------------: | :--------: | :--: |
| `user_uid` | apple-pie-1 |  3.14  | Refund for apple pie |    NULL    | NULL |

```ruby
user_uid = "user_uid_of_your_app"
payment_data = {
  "amount": 3.14,
  "memo": "Refund for apple pie",
  "metadata": {"product_id": "apple-pie-1"}, # this is just an example
  "uid": user_uid
}
# It is critical that you store the payment_id in your database
# so that you don't double-pay the same user, by keeping track of the payment.
payment_id = pi.create_payment(payment_data)
```

3. Store the `payment_id` in your database

After creating the payment, you'll get `payment_id`, which you should be storing in your database.

|    uid     | product_id  | amount |         memo         |  payment_id  | txid |
| :--------: | :---------: | :----: | :------------------: | :----------: | :--: |
| `user_uid` | apple-pie-1 |  3.14  | Refund for apple pie | `payment_id` | NULL |

4. Submit the payment to the Pi Blockchain

```ruby
# It is strongly recommended that you store the txid along with the payment_id you stored earlier for your reference.
txid = pi.submit_payment(payment_id)
```

5. Store the txid in your database

Similarly as you did in step 3, keep the txid along with other data.

|    uid     | product_id  | amount |         memo         |  payment_id  |  txid  |
| :--------: | :---------: | :----: | :------------------: | :----------: | :----: |
| `user_uid` | apple-pie-1 |  3.14  | Refund for apple pie | `payment_id` | `txid` |

6. Complete the payment

```ruby
payment = pi.complete_payment(payment_id, txid)
```

## Overall flow for A2U (App-to-User) payment

To create an A2U payment using the Pi Ruby SDK, here's an overall flow you need to follow:

1. Initialize the SDK

   > You'll be initializing the SDK with the Pi API Key of your app and the Private Seed of your app wallet.

2. Create an A2U payment

   > You can create an A2U payment using `create_payment` method. The method returns a payment identifier (payment id).

3. Store the payment id in your database

   > It is critical that you store the payment id, returned by `create_payment` method, in your database so that you don't double-pay the same user, by keeping track of the payment.

4. Submit the payment to the Pi Blockchain

   > You can submit the payment to the Pi Blockchain using `submit_payment` method. This method builds a payment transaction and submits it to the Pi Blockchain for you. Once submitted, the method returns a transaction identifier (txid).

5. Store the txid in your database

   > It is strongly recommended that you store the txid along with the payment id you stored earlier for your reference.

6. Complete the payment
   > After checking the transaciton with the txid you obtained, you must complete the payment, which you can do with `complete_payment` method. Upon completing, the method returns the payment object. Check the `status` field to make sure everything looks correct.

## SDK Reference

This section shows you a list of available methods.

### `create_payment`

This method creates an A2U payment.

- Required parameter: `payment_data`

You need to provide 4 different data and pass them as a single object to this method.

```ruby
payment_data = {
  "amount": number, # the amount of Pi you're paying to your user
  "memo": string, # a short memo that describes what the payment is about
  "metadata": object, # an arbitrary object that you can attach to this payment. This is for your own use. You should use this object as a way to link this payment with your internal business logic.
  "uid": string # a user uid of your app. You should have access to this value if a user has authenticated on your app.
}
```

- Return value: `a payment identifier (payment_id)`

### `submit_payment`

This method creates a payment transaction and submits it to the Pi Blockchain.

- Required parameter: `payment_id`
- Return value: `a tranaction identifier (txid)`

### `complete_payment`

This method completes the payment in the Pi server.

- Required parameter: `payment_id, txid`
- Return value: `a payment object`

The method returns a payment object with the following fields:

```ruby
payment = {
  # Payment data:
  "identifier": string, # payment identifier
  "user_uid": string, # user's app-specific ID
  "amount": number, # payment amount
  "memo": string, # a string provided by the developer, shown to the user
  "metadata": object, # an object provided by the developer for their own usage
  "from_address": string, # sender address of the blockchain transaction
  "to_address": string, # recipient address of the blockchain transaction
  "direction": string, # direction of the payment ("user_to_app" | "app_to_user")
  "created_at": string, # payment's creation timestamp
  "network": string, # a network of the payment ("Pi Network" | "Pi Testnet")

  # Status flags representing the current state of this payment
  "status": {
    "developer_approved": boolean, # Server-Side Approval (automatically approved for A2U payment)
    "transaction_verified": boolean, # blockchain transaction verified
    "developer_completed": boolean, # Server-Side Completion (handled by the create_payment! method)
    "cancelled": boolean, # cancelled by the developer or by Pi Network
    "user_cancelled": boolean, # cancelled by the user
  },

  # Blockchain transaction data:
  "transaction": nil | { # This is nil if no transaction has been made yet
    "txid": string, # id of the blockchain transaction
    "verified": boolean, # true if the transaction matches the payment, false otherwise
    "_link": string, # a link to the operation on the Pi Blockchain API
  }
}
```

### `get_payment`

This method returns a payment object if it exists.

- Required parameter: `payment_id`
- Return value: `a payment object`

### `cancel_payment`

This method cancels the payment in the Pi server.

- Required parameter: `payment_id`
- Return value: `a payment object`

### `get_incomplete_server_payments`

- Required parameter: `none`
- Return value: `an array which contains 0 or 1 payment object`

This method returns the latest incomplete payment which your app has created, if present.
Use this method to troubleshoot the following error: "You need to complete the ongoing payment first to create
a new one."

If a payment is returned by this method, you must follow one of the following 3 options:

1. cancel the payment, if it is not linked with a blockchain transaction
   and you don't want to submit the transaction anymore

2. submit the transaction and complete the payment

3. if a blockchain transaction has been made, complete the payment

If you do not know what this payment maps to in your business logic, you may use its `metadata` property to retrieve
which business logic item it relates to. Remember that `metadata` is a required argument when creating a payment,
and should be used as a way to link this payment to an item of your business logic.

## Subscription processing (server-side)

Subscriptions run on Pi's on-chain Subscription contract. Renewals don't happen on their own: the merchant (the wallet that owns the subscription service) calls the contract's `process` to collect every payment that is due.

In the Pi Browser, the client SDK's `Pi.SmartContract.Subscription.process` makes the merchant sign in the Pi Wallet and enter the passphrase each time. `PiNetwork::SmartContract::Subscription.process` does the same from your server instead: it builds the call, signs it with the merchant wallet's secret seed and sends it straight to the Pi Soroban RPC server. Nothing goes through the Pi Browser, so it can run from a scheduled job.

> Subscriptions are available only on Pi Testnet for now, and need version 0.2.0.pre.1 or later (see [Versions](#versions)).

### Example

```ruby
require 'pinetwork'

# The merchant wallet's secret seed (starts with S). Keep it on your server only, e.g. in an environment variable.
merchant_secret = ENV.fetch("PI_MERCHANT_SECRET")
service_id = "0" # your service_id on the Subscription contract
batch = 20

# 1. Preview the first batch without signing or sending. :total is how many subscriptions to page through.
preview = PiNetwork::SmartContract::Subscription.process(merchant_secret, service_id, 0, batch, mode: :simulate)

# 2. Collect renewals, one batch per transaction.
(0...preview[:total]).step(batch) do |offset|
  begin
    outcome = PiNetwork::SmartContract::Subscription.process(merchant_secret, service_id, offset, batch)
    puts "#{outcome[:txid]} #{outcome[:result]}" # { charged:, failed:, skipped:, total: }
  rescue PiNetwork::Errors::SubscriptionError => e
    # :transaction_not_confirmed means it was sent but the outcome is unknown: look up e.txid before retrying.
    raise
  end
end
```

### `PiNetwork::SmartContract::Subscription.process`

```ruby
PiNetwork::SmartContract::Subscription.process(
  merchant_secret,    # String: the merchant wallet's secret seed (S...)
  service_id,         # Integer or digit String: the service to process (u64)
  offset,             # Integer or digit String: where to start in the service's subscription list (u32)
  limit,              # Integer or digit String: how many subscriptions to handle in this call (u32)
  mode: :submit,      # :simulate or :submit
  rpc_url: "https://rpc.testnet.minepi.com",
  network_passphrase: "Pi Testnet",
  contract_address: "CCUF75B6W3HRJTJD6O7OXNI72HGJ7DERZ5MUNOMFMSK23ME5GUIKPFYV", # the Pi Testnet Subscription contract
  timeout_seconds: 180   # how long the transaction stays valid (1..4294967295)
)
# An option passed as nil uses its default, the same as leaving it out.
# mode: :simulate => { charged:, failed:, skipped:, total: }
# mode: :submit   => { txid:, ledger:, result: { charged:, failed:, skipped:, total: } }
```

What it does, in order:

1. Checks the arguments. Nothing is sent if one is invalid.
2. Loads the merchant account and builds `process(merchant, service_id, offset, limit)`, with the merchant's public key derived from the secret.
3. Simulates the call. With `mode: :simulate` it stops here and returns the result the call would produce.
4. With `mode: :submit` (the default) it signs the call, sends it and waits for the result (up to `timeout_seconds` plus a few seconds), then returns `{ txid:, ledger:, result: }`.

In the result, `charged` counts subscriptions charged in this batch, `failed` counts charges that failed (the contract turns those subscriptions' auto-renew off), `skipped` counts subscriptions not due yet or not auto-renewing, and `total` is the number of subscriptions the service has. The contract charges every auto-renewing subscription in `offset...offset + limit` whose renewal is due. A failed charge (low balance, used-up allowance, or more than one period late) doesn't stop the batch. Run `process` at least once per billing period.

Errors are raised as `PiNetwork::Errors::SubscriptionError` with a `code` (a Symbol):

| Code | Meaning |
| --- | --- |
| `:invalid_merchant_secret`, `:invalid_service_id`, `:invalid_offset`, `:invalid_limit`, `:invalid_mode`, `:invalid_timeout`, `:invalid_rpc_url`, `:invalid_network_passphrase`, `:invalid_contract_address` | An argument is invalid. Nothing was sent. |
| `:account_not_found` | The merchant account doesn't exist on the network. |
| `:simulation_failed` | The contract refused the call; `contract_error_name` says why (e.g. `NotServiceOwner`, `ServiceShutdown`). Nothing was sent. |
| `:state_archived` | Contract state the call needs is archived and must be restored first. |
| `:fee_too_high` | The fee is larger than a transaction can carry. |
| `:transaction_rejected` | The RPC server didn't accept the transaction (e.g. `txInsufficientBalance`); `detail` has the result code. |
| `:transaction_failed` | The transaction was included but failed; `txid` identifies it. |
| `:transaction_not_confirmed` | Sent, but the outcome is unknown. Look up `txid` before sending again. |
| `:unexpected_response`, `:rpc_error` | The RPC server answered with something unreadable, or a request to it failed. If the error has a `txid`, the transaction was already sent: look it up before running the batch again. |

The merchant account pays the fee. On the default Pi Testnet contract a call has cost about 0.01 to 0.02 Pi. It grows with the number of subscriptions in the batch, and with rent: the contract extends the lifetime of every entry it touches, which costs more when entries are close to expiring. The gem adds 50% headroom to the simulated resource fee (the unused part is refunded), so keep more than that available in the merchant account.

**Don't run `process` at the same time as A2U payments from the same wallet.** Every transaction uses the sending account's next sequence number. If the merchant secret is also your app wallet's seed (the one you pass to `PiNetwork.new(api_key:, wallet_private_key:)`), a `process` call and an A2U payment built at the same moment get the same sequence number, and only one of them lands. On Pi Testnet both outcomes happen:

- The payment lands first and `process` fails. If the payment had already landed when `process` was sent, that's right away, with `:transaction_rejected` and `detail` `"txBadSeq"`. Otherwise the RPC server accepts `process` and then drops it, and it ends in `:transaction_not_confirmed` with `detail` `"NOT_FOUND"` after its validity window (`timeout_seconds`, about 3 minutes by default). Either way it was never included: that batch didn't run and can be run again.
- `process` lands and the payment's `submit_payment` fails or times out.

To avoid it, run them one after the other (for example, run the scheduled `process` job when your server isn't sending payouts, or send both through one queue), or use a separate wallet for one of them.

## Troubleshooting

### Error when creating a payment: "You need to complete the ongoing payment first to create a new one."

See documentation for the `get_incomplete_server_payments` above.
