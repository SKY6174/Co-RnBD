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

## Rollout boundary

The connected production Supabase project has the existing `conference_settings`, `profiles`, and `staff_roles` columns expected by the migration, but it does not yet have the new operations tables. No production migration or real participant write was performed. Full account-to-database browser verification requires applying the migration and deploying the feature branch.
