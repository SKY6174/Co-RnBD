# Conference operations — implementation check

## Matched design

- Single-conference attendee registration is separate from papers and references the existing profile.
- A unique user key prevents duplicate applications. The member sees their status and can cancel; the chair can confirm and check in.
- Speakers, sessions, and their ordered links are chair managed. Public queries return published records only.
- The public pages show an explicit empty state and distinguish the provisional homepage timetable from confirmed program entries.
- Registration remains closed by default. No fees, payment flow, automatic email, or invented speaker/session data were added.

## Verification

- JavaScript syntax checked with `node --check`.
- PostgreSQL migration parsed and executed in isolated PGlite. RLS probes confirmed member confirmation and registering another user were denied; chair confirmation was allowed; anonymous registration reads were denied; anonymous program reads returned only published records and links.
- HTML local references and duplicate IDs checked. `git diff --cached --check` passed.
- Desktop and 390px mobile pages inspected in a browser; no horizontal overflow on the inspected pages.

## Production database verification

On 2026-09-27, the additive migration was applied to the connected Supabase project under remote version `20260927010351`. All four new tables have RLS enabled, 15 operations policies are present, registration remains closed, and attendee and session counts are both zero. The Vercel Preview now reads an empty public program and the closed registration state without a schema error. No real participant write was performed. Full account-to-database verification awaits site deployment and an appropriate test account.
