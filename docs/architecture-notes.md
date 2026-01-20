# Architecture Notes — Pi Ruby SDK

This document provides architectural notes and design considerations
for the Pi Ruby SDK. It is intended to help developers understand
system boundaries, responsibilities, and recommended usage patterns.

This document is descriptive, not prescriptive, and does not represent
an official roadmap or commitment.

---

## 1. Architectural Positioning

The Pi Ruby SDK operates at the **application backend layer** and serves
as a secure integration interface between:

- A Ruby-based backend application
- The Pi Platform Server APIs
- The Pi Blockchain network (Testnet or Mainnet)

The SDK does **not** function as:
- A smart contract framework
- A blockchain node
- A price oracle or valuation mechanism

---

## 2. Hybrid Payment Model

The SDK implements a **hybrid off-chain / on-chain payment flow**:

| Stage | System | Responsibility |
|------|--------|----------------|
| Payment Creation | Pi Platform Server | Payment intent registration and anti-duplication |
| Transaction Submission | Pi Blockchain | Value transfer and settlement |
| Payment Completion | Pi Platform Server | Transaction verification and finalization |

This design enables fraud prevention, auditability, and deterministic
payment lifecycle management.

---

## 3. Payment Lifecycle and State Management

Payments progress through a defined lifecycle:

1. Initialized (`create_payment`)
2. Submitted (`submit_payment`)
3. Verified (blockchain confirmation)
4. Completed (`complete_payment`)
5. Cancelled (optional terminal state)

While the SDK exposes granular methods, applications are expected
to persist `payment_id` and `txid` to ensure idempotency and recovery.

---

## 4. Error Handling and Transaction Timing

Blockchain submission is subject to timing constraints and network state.
The SDK includes retry handling for specific transient errors
(e.g. `tx_too_early`) to improve reliability.

Applications should still treat all payment operations as
**potentially asynchronous** and resilient to retries.

---

## 5. Idempotency and Backend Safety

The SDK design assumes that:
- Backend services may retry requests
- Network interruptions may occur
- Payment operations must be resumable

To support this:
- `payment_id` serves as the primary idempotency key
- `get_incomplete_server_payments` enables recovery of interrupted flows
- Transaction verification is performed server-side by Pi Platform

---

## 6. Environment Awareness

The SDK may operate against different Pi Network environments
(e.g. Testnet or Mainnet). Applications should explicitly separate
configuration and credentials per environment to avoid cross-network
confusion.

---

## 7. Design Constraints and Non-Goals

The following are explicitly out of scope for the Pi Ruby SDK:

- Price discovery or exchange integration
- Decentralized governance logic
- Smart contract execution
- On-chain oracle systems

These constraints are intentional and align with Pi Network’s
application-first ecosystem model.

---

## 8. Security Considerations

- API keys and wallet private seeds must never be exposed to clients
- All SDK usage should occur server-side
- Payment state must be stored durably in application databases

Failure to follow these guidelines may result in fund loss
or policy violations.

---

## Disclaimer

This document is provided for architectural clarity only.
Implementation details may evolve without notice.
All final authority rests with the Pi Network Core Team
and repository maintainers.
