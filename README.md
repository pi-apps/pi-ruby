# Pi Ruby

This is a Ruby gem to integrate the Pi Network apps platform with a Ruby-based backend application.

## Overall flow for A2U (App-to-User) payment

To create an A2U payment using the Pi Ruby SDK, here's an overall flow you need to follow:

1. Initialize the SDK
> You'll be initializing the SDK with the Pi API Key of your app and the Private Seed of your app wallet.

2. Create an A2U payment
> `create_payment!` method will handle everything from the beginning to the end of the process.

> **WARNING** Since this single method takes care of the entire process, *i.e. requesting a payment to the Pi server, submitting the transaction to the Pi blockchain and completing the payment,* it can take a few seconds, roughly less than 10 seconds, to complete the call.


3. Check the payment status
> When `create_payment!` is completed successfully, it returns the payment object you created on the Pi server. Check the `status` field to make sure everything looks correct.


## SDK Reference

Here's a list of available methods. While there exists only one method at the moment, we will be providing more methods in the future, and this documentation will be updated accordingly.
### create_payment!

A single method that takes care of the entire A2U payment flow.

These are the steps that are handled by this method under the hood:
1. An A2U payment gets created on the Pi server
2. A payment transaction gets built
3. The transaction gets submitted to the Pi Blockchain
4. A payment status gets updated to be "complete" on the Pi server

- Required parameter: payment_data

You need to provide 4 different data and pass them as a single object to this method.
1. `amount`: the amount of Pi you're paying to your user
2. `memo`: a short memo that describes what the payment is about
3. `metadata`: an arbitrary object that you can attach to this payment. This is for your own use. You should use this object as a way to link this payment with your internal business logic.
4. `uid`: a user uid of your app. You should have access to this value if a user has authenticated on your app.

- Response: a payment object

The method will return a payment object that looks like the following:

```ruby
payment = {
  # Payment data:
  identifier: string, # payment identifier
  user_uid: string, # user's app-specific ID
  amount: number, # payment amount
  memo: string, # a string provided by the developer, shown to the user
  metadata: object, # an object provided by the developer for their own usage
  from_address: string, # sender address of the blockchain transaction
  to_address: string, # recipient address of the blockchain transaction
  direction: string, # direction of the payment ("user_to_app" | "app_to_user")
  created_at: string, # payment's creation timestamp
  network: string, # a network of the payment ("Pi Network" | "Pi Testnet")

  # Status flags representing the current state of this payment
  status: {
    developer_approved: boolean, # Server-Side Approval (automatically approved for A2U payment)
    transaction_verified: boolean, # blockchain transaction verified
    developer_completed: boolean, # Server-Side Completion (handled by the create_payment! method)
    cancelled: boolean, # cancelled by the developer or by Pi Network
    user_cancelled: boolean, # cancelled by the user
  },

  # Blockchain transaction data:
  transaction: nil | { # This is nil if no transaction has been made yet
    txid: string, # id of the blockchain transaction
    verified: boolean, # true if the transaction matches the payment, false otherwise
    _link: string, # a link to the operation on the Pi Blockchain API
  },
}
```


## Install

1. Add the following line to your Gemfile:
```ruby
gem 'pi_network'
```

2. Install the gem
```ruby
$ bundle install
```


## Example

1. Initialize the SDK
```ruby
require 'pi_network'

# DO NOT expose these values to public
api_key = "YOUR_PI_API_KEY"
wallet_private_seed = "S_YOUR_WALLET_PRIVATE_SEED" # starts with S

pi = PiNetwork.new(api_key, wallet_private_seed)
```

2. Create an A2U payment
```ruby
user_uid = "user_uid_of_your_app"
payment_data = {
  "amount": 1,
  "memo": "From app to user test",
  "metadata": {"test": "your metadata"},
  "uid": user_uid
}

# check the status of the returned payment!
payment = pi.create_payment!(payment_data)
```