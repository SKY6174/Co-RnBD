# Conference operations — design

## Data model

- `conference_settings`: add `registration_open` (false by default) and `registration_deadline` (2026-10-30 18:00 KST, the already confirmed general-attendee deadline).
- `attendee_registrations`: one row per Auth user; category (`student`, `faculty`, `industry`, `other`), requested days as a constrained date array, status (`applied`, `confirmed`, `cancelled`), and optional chair check-in timestamp. Names and emails remain in `profiles`.
- `program_speakers`: name, affiliation, short bio, publication flag. Chair writes, public reads only published records.
- `program_sessions`: title, type, start/end, room, summary, publication flag. A published session must have required schedule details.
- `program_session_speakers`: ordered many-to-many links. The public can read links only when both the session and speaker are published.

## Access and workflow

Authenticated members apply or cancel their own registrations. A trigger validates the registration window and prevents member confirmation/check-in and identity changes. Chair can read all applications, confirm/cancel, and check in. Unique `user_id` prevents duplicates. No payment, ticket number, or auto-email.

`program.html` renders only published sessions and their published speaker details. Chair uses `operations.html` to create/edit speakers and sessions, set speaker links, and publish once confirmed. Drafts are never visible to anonymous visitors. The chair can see drafts. The program starts empty rather than inventing names, rooms, or talk times.

`registration.html` uses the existing Supabase session. Unauthenticated visitors can start Google or Naver OAuth directly on the registration page and return there after authentication; the existing submission portal remains the email login and signup entry point. Provider availability follows the submission portal's Google Auth settings and Naver site configuration. The registration form reuses profile name, affiliation, and email and requires completeness. Application success means pending review; the chair explicitly confirms. Registration has no fee field until fees are approved.

## Verification

Validate schema and RLS with a rollback-only SQL transaction or local database, inspect public and member UI at desktop/mobile widths, run `node --check`, check HTML links/IDs, and inspect a Preview without writing real attendee records.
