-- Open general attendee registration for the 2026 edition through 2027-01-05 18:00 KST.
-- Preserve any independently changed chair settings and all paper-stage switches.
do $$
begin
  update public.conference_settings s
  set registration_open = true
  where s.edition_year = 2026
    and s.registration_deadline = '2027-01-05 18:00:00+09'
    and s.registration_open = false
    and exists (
      select 1 from public.conference_editions e
      where e.year = s.edition_year and e.status = 'current'
        and e.start_date = '2027-01-21' and e.end_date = '2027-01-22'
    );
  if not found then
    raise exception 'Review current 2026 registration settings before opening applications';
  end if;
end;
$$;

-- Conditional rollback after an operational decision to close registration:
-- update public.conference_settings
-- set registration_open = false
-- where edition_year = 2026
--   and registration_deadline = '2027-01-05 18:00:00+09' and registration_open = true;
