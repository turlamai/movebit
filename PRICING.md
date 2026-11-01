# MoveBit product and pricing policy

**English** · [简体中文](PRICING.zh-CN.md)

## Status and policy revision

Policy revision: `2026-10-commercial-1` (2026-10-30). This supersedes the 2026-10-23 free-only/no-Permit decision after the MoveBit reboot. **Free + Pro is an approved direction, not an announcement of prices, shipped paid features, live checkout or launch readiness.** No actual purchasers or migration cohort are asserted.

## Editions

- **Free:** complete useful local water/stand/eye reminders, safe Done/Later/Focus actions, essential configuration and access to existing personal history, backup/export and recovery. Existing usable data must never become inaccessible because a license is absent, expired or refunded.
- **Pro (planned):** optional, genuinely additive value such as advanced personalization, extended insights or richer character experiences **only after those capabilities are specified, implemented, tested and documented**. Do not label currently-free core behavior Pro or claim an unimplemented capability.
- One-time purchase vs subscription, trial duration, device/seat limits, refund rules, offline grace, region-specific amounts and upgrade economics remain open product decisions. **Do not invent a price or offer payment before they are approved.**

## Integration contract

- Use [Permit](https://github.com/turlamai/permit) Protocol v1 for signed local rights in the **shared Racket domain core**. Windows/macOS/Linux hosts display typed entitlement states; they do not replicate cryptographic or policy logic.
- Use [Commerce](https://github.com/turlamai/commerce) for optional hosted checkout, verified payment-to-rights issuance and claim/restore. No payment-provider secret or Permit issuer private key ships inside applications. A successful browser redirect is not proof of payment.
- Free mode needs neither a login nor a network connection. Purchased rights should be offline-verifiable under the selected policy. Signed update verification and product-license verification use separate trust and keys.
- Paid entitlements govern only official product features/services, not rights already granted by the MIT [source license](LICENSE). Keep source use, modification and distribution terms truthful and independent of paid binaries or services.

## Rollout gates

1. Close the product/feature policy and approved offer definitions through [#81](https://github.com/turlamai/movebit/issues/81).
2. Add a reusable core entitlement adapter and negative/upgrade/restore tests without enabling paid gates in released builds.
3. Add native, accessible license/trial/recovery UI and three-platform parity tests.
4. Run Commerce sandbox purchase → authenticated event → Permit signing → one-time claim → offline verification, plus refunds, duplicate events and support recovery.
5. Enable live sales **only after** Commerce merchant eligibility, signing isolation, payment reconciliation and end-to-end release gates pass. Security fixes, reading/backup/export, and existing data recovery stay available without a purchase.

This document expresses a product direction, not evidence that implementation or payment activation has happened.
