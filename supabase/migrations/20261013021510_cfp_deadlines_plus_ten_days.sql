-- User-requested ten-day CFP schedule extension, 2026 edition only.
-- Keep stage switches and proposed paper-stage deadlines unchanged.
-- Preserve any different deadline set independently by the chair.
update public.conference_settings
set registration_deadline = '2026-12-14 18:00:00+09'
where edition_year = 2026
  and registration_deadline = '2026-12-04 18:00:00+09';

-- Rollback if required:
-- update public.conference_settings
-- set registration_deadline = '2026-12-04 18:00:00+09'
-- where edition_year = 2026
--   and registration_deadline = '2026-12-14 18:00:00+09';
