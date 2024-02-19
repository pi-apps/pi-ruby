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

## Example

1. Initialize the SDK

```ruby
require 'pinetwork'

# DO NOT expose these values to public
api_key = "YOUR_PI_API_KEY"
wallet_private_seed = "S_YOUR_WALLET_PRIVATE_SEED" # starts with S

pi = PiNetwork.new(api_key: api_key, wallet_private_seed: wallet_private_seed)
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

## Troubleshooting

### Error when creating a payment: "You need to complete the ongoing payment first to create a new one."

See documentation for the `get_incomplete_server_payments` above.
