# Changelog

## 0.2.0.pre.1 (unreleased prerelease)

Published as a prerelease: Bundler and RubyGems install it only when asked for by its exact version (`gem 'pinetwork', '0.2.0.pre.1'`) or with `gem install pinetwork --pre`, so projects on 0.1.x are not affected. After it has been tried, release it as 0.2.0.

### Added

- `PiNetwork::SmartContract::Subscription.process(merchant_secret, service_id, offset, limit, **options)`: runs the Pi Subscription contract's `process` from your server. It signs with the merchant wallet's secret seed and sends the call straight to the Pi Soroban RPC server, so renewals can be collected by a scheduled job instead of through the Pi Browser. Same path and argument order as the client SDK's `Pi.SmartContract.Subscription.process` and the Node.js package's `SmartContract.Subscription.process`.
- `PiNetwork::Errors::SubscriptionError`, with a `code` for each failure and the contract error's name when the contract refuses a call.

### Compatibility

- No breaking changes: the payment methods, their arguments and the gem's dependencies are unchanged.
- Loads on Ruby 2.5 and later again, like 0.1.5: the unreleased transaction time-bounds change on main used Ruby 3.1 keyword shorthand (`min_time:, max_time:`), which is now written out.

### Fixed

- README: the constructor example passes `wallet_private_key:` (it said `wallet_private_seed:`, which raises `ArgumentError`).

### Included from main since 0.1.5

- Retry a transaction submission on `tx_too_early`, and handle Horizon error responses on submission (#31, #32).

## 0.1.5

The version current users run. A2U payments only.
