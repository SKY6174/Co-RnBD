# Annual conference editions and archive

## Goal

Keep the 2026 conference working while allowing the chair to prepare later yearly editions in the same Supabase project. Preserve each year's submissions, registrations, and program separately. Provide a public archive that exposes only explicitly published conference metadata and program.

## Scope

- Add a yearly edition record and bind settings, papers, registrations, speakers, and sessions to it. Backfill existing rows to 2026.
- Allow a chair to create a draft edition, edit its public facts, and activate it after the previous event ends. Activation closes the old edition and its workflow switches.
- Give current-year pages a database-driven edition context. Preserve the 2026 home and CFP content; use a generic edition landing page for later years.
- List published archived editions on a separate page with year-specific public details and program. Never publish submitted PDFs, review notes, or participant records through the archive.
- Keep 2026 data and URLs intact. Do not invent 2027/2028 event dates, venues, programs, or call text.

## Acceptance

- Existing 2026 data is assigned to 2026, and the current workflow behaves as before.
- One current edition exists; drafts have closed workflow settings. The chair can prepare future years without affecting current users.
- Archived records cannot be changed through normal author, reviewer, registration, or program writes.
- Public archive shows only archive-published editions and published program rows.
- Annual data queries and writes are scoped to the active edition; mobile layout stays usable.
