# Gap Analysis: session-chair-selection

> Date: 2026-09-28 | Design: `docs/02-design/features/session-chair-selection.design.md`

## Match Rate: 94% (16/17)

The implementation covers the application, selection, assignment and withdrawal boundaries in the design. The recruitment switch defaults to closed, and no CFP or program link has been added while the organizer's eligibility, criteria, registration rule and dates are undecided.

## Implemented

1. Current-edition setting with closed default, deadline and notice guard.
2. Existing account/profile reuse; no new phone or address fields.
3. One application per edition and account, with preferred oral/poster format and conference dates.
4. Submitted, approved, declined and withdrawn states with DB-checked transitions.
5. Applicant-only read/write and chair-only full list through RLS.
6. Private review notes in a separate chair-only table.
7. Profile completeness and current-edition validation at the DB boundary.
8. Approval does not grant `staff_roles` or session access.
9. New `session_chairs` assignments require an approved applicant matching the session format and KST date.
10. Existing session assignments remain intact; no synthetic application records are added.
11. Direct withdrawal before assignment and a non-destructive request after assignment.
12. Applicant page with closed, submitted, selected, rejected, withdrawn and request states.
13. Chair page with list, private note, decision and approved-account suggestions.
14. No automatic mail or public candidate list.
15. Privacy-policy scope, processing items, access and retention updated.
16. Local database checks for closed-window rejection, self/other/chair RLS, private notes, unapproved assignment rejection, approved assignment and withdrawal paths; syntax, typecheck, build, route and HTML checks passed.

## Remaining verification

- Authenticated browser flows and responsive 390px layout have not been exercised with a local test account. The local page route renders, but its client reports missing data configuration without a Supabase URL and publishable key.
- Vercel Preview must not write to production Supabase. The migration has only been applied to a disposable local database.

## Operational decisions before opening recruitment

The organizer must confirm eligibility, selection criteria, any participant-registration condition, deadline, and result notice wording. Add the public CFP/program link only after those decisions. Applying the migration, opening recruitment and deploying to production are separate actions.
