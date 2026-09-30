-- A named annual edition may meet early in the following calendar year.
-- Preserve the 2026 edition identity while moving its confirmed event dates.
alter table public.conference_editions drop constraint edition_dates;
alter table public.conference_editions add constraint edition_dates check (
  (start_date is null and end_date is null) or
  (start_date is not null and end_date is not null
    and start_date <= end_date and end_date - start_date < 7
    and extract(year from start_date) in (year, year + 1)
    and extract(year from end_date) in (year, year + 1))
);

-- Do not silently move existing participant choices or published program times.
do $$
begin
  if exists (
    select 1 from public.attendee_registrations
    where edition_year = 2026
      and not (attendance_days <@ array['2027-01-14'::date, '2027-01-15'::date])
  ) then
    raise exception 'Review 2026 attendee registration days before changing conference dates';
  end if;
  if exists (
    select 1 from public.program_sessions
    where edition_year = 2026 and starts_at is not null
      and ((starts_at at time zone 'Asia/Seoul')::date < '2027-01-14'::date
        or (ends_at at time zone 'Asia/Seoul')::date > '2027-01-15'::date)
  ) then
    raise exception 'Review 2026 program session times before changing conference dates';
  end if;
end;
$$;

do $$
begin
  update public.conference_editions
  set start_date = '2027-01-14', end_date = '2027-01-15'
  where year = 2026 and status = 'current';
  if not found then
    raise exception 'Current 2026 conference edition was not found';
  end if;
end;
$$;

-- Preserve a chair-edited deadline; only shift the previous confirmed value.
-- Paper-stage deadlines remain null until the proposed schedule is approved.
update public.conference_settings
set registration_deadline = '2026-11-27 18:00:00+09'
where edition_year = 2026
  and registration_deadline = '2026-10-30 18:00:00+09';
