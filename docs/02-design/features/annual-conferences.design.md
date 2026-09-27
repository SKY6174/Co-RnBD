# Annual conference editions: design

## Data model

`conference_editions(year PK, title, start_date, end_date, venue, summary, status, archive_published, proceedings_url)` is the parent. Status is `draft`, `current`, or `archived`; a partial unique index permits at most one current row. The 2026 row is seeded with known dates and venue. `conference_settings` becomes one row per year. `papers`, `attendee_registrations`, `program_speakers`, and `program_sessions` gain a required `edition_year` FK, backfilled to 2026. Paper authors/files/reviews inherit the year through paper. Session-speaker links must refer to the same year.

Creating a year is a chair-only database function that adds a draft edition and closed settings atomically. Activating a year is another chair-only transaction: require valid dates, an ended previous edition, then archive the old row with all workflow switches off and mark the new row current. Publication of the archive is a separate chair action after reviewing public content. Edition status changes cannot be made by a direct table update.

RLS grants public read of current edition facts and explicitly published archives; drafts are chair-only. Program policies require both row publication and edition visibility. Existing authors/reviewers may retain private access to their records, but all writes to archived editions are denied by database triggers. Only the chair may manage editions and settings.

## Pages

- `index.html`: 2026 landing; when a later edition becomes current, navigate to generic `edition.html`.
- `edition.html`: current edition or an archive edition by `?year=`; show verified facts, summary, published program link, and current workflow links only for the active edition.
- `archive.html`: separate year list for published archived editions. An unpublished archive is not listed.
- Current registration, program, operations, and submission pages query the current edition and scope annual rows.
- Operations page manages draft editions, activation, and archive publication. No automatic rollover or invented dates.

## Verification

Run migration in an isolated Postgres-compatible environment or rollback transaction. Check FK/backfill, one-current uniqueness, cross-edition linkage, archived write guards, and public RLS. Run JS syntax checks and inspect pages at mobile and desktop widths. Production migration and deployment require explicit approval under repository guidance.
