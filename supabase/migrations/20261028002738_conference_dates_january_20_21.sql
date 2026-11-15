-- User-confirmed event date change. Paper/registration deadlines stay unchanged.
-- Abort if dependent operational records need an individually reviewed date move.
do $$
begin
  lock table public.attendee_registrations, public.program_sessions
    in share row exclusive mode;

  if exists (select 1 from public.conference_editions
    where year = 2026 and status = 'current'
      and start_date = date '2027-01-20' and end_date = date '2027-01-21') then
    return;
  end if;

  perform 1 from public.conference_editions
  where year = 2026 and status = 'current'
    and start_date = date '2027-01-21' and end_date = date '2027-01-22'
  for update;
  if not found then
    raise exception 'Expected current 2026 edition with January 21-22 dates';
  end if;

  if exists (select 1 from public.attendee_registrations where edition_year = 2026)
    or exists (select 1 from public.program_sessions where edition_year = 2026)
    or exists (select 1 from public.registration_documents d
      join public.attendee_registrations r on r.id = d.registration_id
      where r.edition_year = 2026) then
    raise exception 'Review dependent registrations, sessions and documents before shifting dates';
  end if;

  update public.conference_editions
  set start_date = date '2027-01-20', end_date = date '2027-01-21'
  where year = 2026 and status = 'current'
    and start_date = date '2027-01-21' and end_date = date '2027-01-22';
end;
$$;

-- Rollback before dependent records are created (otherwise review them first):
-- update public.conference_editions
-- set start_date = date '2027-01-21', end_date = date '2027-01-22'
-- where year = 2026 and status = 'current'
--   and start_date = date '2027-01-20' and end_date = date '2027-01-21';
