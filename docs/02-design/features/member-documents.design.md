# Member documents — design (2026-10-15)

## Confirmed direction
User chose automatic generation from registration information. The initial upload proposal is superseded; no new Storage bucket or PDF upload is needed. Browser A4 print produces PDF through the standard print dialog.

## Data
- `document_issuers`: per-edition issuer name, representative, address, optional business/organization number, email and enabled flag. Chair writes; authenticated users read. Required fields before enabling. No invented default details, seal or tax classification.
- `registration_billing`: per-registration approved fee in KRW, state unpaid/paid/waived/refunded, manual payment method transfer/cash/other, paid timestamp when paid/refunded. Chair writes; owner/chair reads. Whole-amount manual verification only. No automatic bank verification, gateway, card data or charge.
- `registration_documents`: registration id, kind attendance/receipt/statement, server document number, snapshot, issued actor/time, issued/revoked state and revoke reason/actor/time. Partial unique index gives one issued document per registration/kind. Rows remain immutable except one-way revocation.

## Server rules
Confirmed registration required for all kinds; attendance additionally requires check-in; receipt requires positive fee + paid state + paid timestamp; statement requires fee configured. Issuer must be enabled. An internal fixed-search-path trigger rebuilds the snapshot from actual DB rows and stamps issue metadata regardless of client input. RLS permits owner/chair insert, select; only chair update. All direct REST inserts get the same validation. Issue RPC (SECURITY INVOKER) serializes on the registration and reuses the existing active issue. Billing writes also lock the registration and revoke financial documents on changes. Registration cancellation/check-in reversal revokes affected documents. Source profile/issuer changes do not silently rewrite historic snapshots; operator can explicitly revoke/reissue.

All private table grants exclude anon. No exposed SECURITY DEFINER RPC. The internal trigger needs SECURITY DEFINER only to read source data consistently and perform automatic revocation; it checks auth+role/ownership explicitly, fixes search_path and revokes direct EXECUTE. Parent row locks coordinate issuance and billing/cancellation changes. Invalid updates do not commit partial revocation.

## UI
- `mypage.html`: profile summary; own history across editions; registration status and manual payment status; each document has ready/unavailable/revoked state, issue-and-view action. Login return uses a fixed destination allowlist. Logout clears personal DOM immediately.
- `document-admin.html`: edition selector, issuer configuration, participant search, confirmed registration/check-in status, manual billing form with explicit verification checkbox, issuance and revocation history. No bulk/automatic payment confirmation. Separate from paper reviews.
- `document.html?id=...`: authenticated owner/chair reads a saved snapshot and renders an A4 document with logo, issue number/date, conference and recipient details, fee/payment information as applicable. Print button rechecks current issue state; revoked documents cannot be freshly printed. Existing saved/printed copies cannot be recalled. Clear labeling that organizer receipts are not automatically tax invoices/cash receipts.
- Dedicated scoped CSS; links from home/submission/registration/operations. Existing privacy retention deadline remains; the new issue/history capability does not authorize long-term retention. Show existing policy link and document that post-event retention must be settled by organizer before that operation.

## Verification/release
Test actual local DB/Auth and desktop390/1440 browser: setup gates, three types, billing/issuer forged by member blocked, snapshots cannot be forged, cross-user/anon denied, simultaneous issues reuse one id, paid-to-refunded revokes receipt, reissue numbers/history, checked-in gate, archive registration history, signout and print dimensions. TypeScript/build/syntax/diff; production schema/advisor/read-only pages checks. Production has no test participants or payment writes. New fields start unconfigured, so operations configure issuer/fees explicitly before real issuance.
