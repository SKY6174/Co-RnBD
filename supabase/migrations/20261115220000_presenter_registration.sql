-- Presenter registration through the same attendee registration form
-- (operator decision 2026-11-15). New category 'presenter', available only to the owner or a
-- listed author (verified login email) of an accepted paper in that edition, and open until the
-- final paper and presenter registration deadline (conference_settings.final_deadline), even after
-- general registration closes. Same fee, confirmation, check-in, payment and documents.
alter table public.attendee_registrations drop constraint attendee_registrations_category_check;
alter table public.attendee_registrations add constraint attendee_registrations_category_check
  check (category in ('student', 'faculty', 'industry', 'other', 'presenter'));

create function app_private.is_presenter_eligible(p_user uuid, p_year integer) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.papers p
    where p.edition_year = p_year and p.status = 'accepted'
      and (p.owner_id = p_user or exists (
        select 1 from public.paper_authors a join auth.users u on u.id = p_user
        where a.paper_id = p.id and u.email_confirmed_at is not null
          and lower(btrim(a.email)) = lower(btrim(u.email))))
  );
$$;
revoke all on function app_private.is_presenter_eligible(uuid, integer) from public, anon, authenticated;

-- For the registration screen: may the current user choose the presenter category?
create function public.presenter_registration_eligible(p_year integer) returns boolean
language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and app_private.is_presenter_eligible(auth.uid(), p_year);
$$;
revoke all on function public.presenter_registration_eligible(integer) from public, anon;
grant execute on function public.presenter_registration_eligible(integer) to authenticated;

create or replace function app_private.guard_attendee_registration() returns trigger
language plpgsql security definer set search_path = '' as $$
declare is_chair_user boolean := app_private.is_chair();
declare window_open boolean;
declare presenter_open boolean;
declare event_start date;
declare event_end date;
begin
  if tg_op = 'UPDATE' and (
    new.id <> old.id or new.user_id <> old.user_id or new.edition_year <> old.edition_year
    or new.created_at is distinct from old.created_at
  ) then raise exception 'Registration owner and conference cannot be changed'; end if;
  select s.registration_open and now() <= s.registration_deadline,
    case when s.final_deadline is null then s.registration_open and now() <= s.registration_deadline
      else now() <= s.final_deadline end,
    e.start_date, e.end_date
    into window_open, presenter_open, event_start, event_end
    from public.conference_settings s join public.conference_editions e on e.year = s.edition_year
    where s.edition_year = new.edition_year and e.status = 'current';
  if event_start is null or event_end is null or exists (
    select 1 from unnest(new.attendance_days) day where day < event_start or day > event_end
  ) or (select count(distinct day) from unnest(new.attendance_days) day) <> cardinality(new.attendance_days)
  then raise exception 'Attendance days must be unique dates within the conference'; end if;
  if new.category = 'presenter' and not is_chair_user
    and not app_private.is_presenter_eligible(new.user_id, new.edition_year) then
    raise exception 'Presenter registration requires an accepted paper';
  end if;
  -- Presenters register until the final paper and presenter registration deadline.
  if new.category = 'presenter' then window_open := presenter_open; end if;
  if not is_chair_user then
    if new.user_id <> (select auth.uid()) then raise exception 'Registration owner must be the current user'; end if;
    if tg_op = 'INSERT' then
      if not coalesce(window_open, false) then raise exception 'Registration is closed'; end if;
      if new.status <> 'applied' or new.checked_in_at is not null then raise exception 'Only the chair may confirm or check in'; end if;
    else
      if new.checked_in_at is distinct from old.checked_in_at or new.status = 'confirmed'
        or (old.status = 'confirmed' and new.status <> 'cancelled') then
        raise exception 'Only the chair may confirm or check in';
      end if;
      if new.status = 'cancelled' and old.status <> 'cancelled' then
        if new.category is distinct from old.category or new.attendance_days is distinct from old.attendance_days
        then raise exception 'Cancel without changing registration details'; end if;
      elsif not coalesce(window_open, false) then raise exception 'Registration is closed'; end if;
    end if;
    if new.status = 'applied' and not exists (
      select 1 from public.profiles where user_id = new.user_id
        and btrim(full_name) <> '' and btrim(affiliation) <> ''
    ) then raise exception 'Name and affiliation are required'; end if;
  end if;
  new.updated_at := now();
  return new;
end;
$$;
