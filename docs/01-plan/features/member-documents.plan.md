# Member documents — plan (2026-10-15)

User clarified: **generate documents automatically from registration information**, rather than operator PDF uploads.

## Goal/scope
- My Page: own yearly registrations and automatic attendance certificates, receipts and transaction statements; print/save PDF.
- Chair document administration: real issuing-organization details, registration fee and manually verified payment status, issue/revoke history.
- Certificates require confirmed attendance/check-in; receipts require verified payment; statements use a configured fee. Unknown fees/issuer details block issuance with an explanation.
- Server-generated immutable snapshots and owner/chair RLS. Payment data cannot be edited by members. No online charging, invented fees, tax receipts, official seals or automatic emails.
- Recommend future PG integration separately.

## Acceptance/release
Real isolated Auth/Postgres/browser verification of eligible issuance, deny rules, snapshot integrity, revocation after billing changes, cross-member access, login return and mobile/print. Additive production migration; PR, preview, merge, production deployment and readonly verification authorized. Existing business data is preserved; rollback disables issuing and restores frontend while retaining history.
