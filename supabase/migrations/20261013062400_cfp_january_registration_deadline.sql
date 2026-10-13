-- Latest user-requested registration deadline for the 2026 edition.
-- Preserve any independently chair-edited value and all paper-stage settings.
update public.conference_settings
set registration_deadline = '2027-01-05 18:00:00+09'
where edition_year = 2026
  and registration_deadline = '2026-12-14 18:00:00+09';

-- Rollback if required:
-- update public.conference_settings
-- set registration_deadline = '2026-12-14 18:00:00+09'
-- where edition_year = 2026
--   and registration_deadline = '2027-01-05 18:00:00+09';
