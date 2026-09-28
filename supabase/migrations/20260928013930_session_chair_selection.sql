-- Interest in chairing is separate from authority over a specific session.
alter table public.conference_settings
  add column chair_applications_open boolean not null default false,
  add column chair_application_deadline timestamptz,
  add column chair_application_notice text not null default ''
    check (char_length(chair_application_notice) <= 2000);

create function app_private.guard_chair_application_settings() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.chair_applications_open and (
    new.chair_applications_open is distinct from old.chair_applications_open or
    new.chair_application_deadline is distinct from old.chair_application_deadline or
    new.chair_application_notice is distinct from old.chair_application_notice
  ) and (new.chair_application_deadline is null or new.chair_application_deadline <= now()
    or char_length(btrim(new.chair_application_notice)) < 20) then
    raise exception 'Set an approved notice and a future deadline before opening chair applications';
  end if;
  return new;
end;
$$;
revoke all on function app_private.guard_chair_application_settings() from public;
create trigger guard_chair_application_settings before update on public.conference_settings
  for each row execute function app_private.guard_chair_application_settings();

create table public.session_chair_applications (
  id uuid primary key default gen_random_uuid(),
  edition_year integer not null references public.conference_editions(year),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  preferred_types text[] not null,
  available_days date[] not null,
  status text not null default 'submitted'
    check (status in ('submitted', 'approved', 'declined', 'withdrawn')),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  withdrawal_requested_at timestamptz,
  unique (edition_year, user_id)
);
create index session_chair_applications_status_idx
  on public.session_chair_applications (edition_year, status, submitted_at);

create table public.session_chair_application_reviews (
  application_id uuid primary key references public.session_chair_applications(id) on delete cascade,
  note text not null default '' check (char_length(note) <= 1000),
  reviewed_by uuid references public.profiles(user_id),
  updated_at timestamptz not null default now()
);

create function app_private.chair_application_window_open(p_year integer) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.conference_settings s
    join public.conference_editions e on e.year = s.edition_year
    where s.edition_year = p_year and e.status = 'current'
      and s.chair_applications_open and s.chair_application_deadline > now()
  );
$$;
revoke all on function app_private.chair_application_window_open(integer) from public;

create function app_private.chair_applicant_assigned(p_year integer, p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.session_chairs sc
    join public.program_sessions s on s.id = sc.session_id
    where s.edition_year = p_year and sc.user_id = p_user_id
  );
$$;
revoke all on function app_private.chair_applicant_assigned(integer, uuid) from public;

create function app_private.guard_chair_application() returns trigger
language plpgsql security definer set search_path = '' as $$
declare event_start date; event_end date; is_assigned boolean; is_chair_user boolean;
begin
  if tg_op = 'UPDATE' and (new.id <> old.id or new.edition_year <> old.edition_year
    or new.user_id <> old.user_id) then
    raise exception 'Application owner and conference cannot be changed';
  end if;
  select e.start_date, e.end_date into event_start, event_end
    from public.conference_editions e
    where e.year = new.edition_year and e.status = 'current';
  if event_start is null or event_end is null then
    raise exception 'Only the current conference with confirmed dates accepts chair applications';
  end if;
  if cardinality(new.preferred_types) not between 1 and 2
    or new.preferred_types <@ array['oral', 'poster']::text[] is not true
    or array_position(new.preferred_types, null) is not null
    or (select count(distinct value) from unnest(new.preferred_types) value) <> cardinality(new.preferred_types)
    or cardinality(new.available_days) not between 1 and 31
    or array_position(new.available_days, null) is not null
    or exists (select 1 from unnest(new.available_days) day
      where day < event_start or day > event_end)
    or (select count(distinct day) from unnest(new.available_days) day) <> cardinality(new.available_days)
  then raise exception 'Choose valid presentation types and unique conference dates'; end if;

  is_chair_user := app_private.is_chair();
  is_assigned := app_private.chair_applicant_assigned(new.edition_year, new.user_id);
  if tg_op = 'INSERT' then
    if new.user_id <> (select auth.uid()) or not app_private.chair_application_window_open(new.edition_year)
      or new.status <> 'submitted' or new.reviewed_at is not null
      or new.withdrawal_requested_at is not null then
      raise exception 'Only the applicant may submit during the open period';
    end if;
    if not exists (select 1 from public.profiles p where p.user_id = new.user_id
      and btrim(p.full_name) <> '' and btrim(p.affiliation) <> ''
      and cardinality(p.expertise_tracks) between 1 and 3) then
      raise exception 'Complete name, affiliation and expertise before applying';
    end if;
    new.submitted_at := now();
    return new;
  end if;

  if is_chair_user then
    if new.preferred_types is distinct from old.preferred_types
      or new.available_days is distinct from old.available_days
      or new.submitted_at is distinct from old.submitted_at then
      raise exception 'The conference chair cannot edit applicant preferences';
    end if;
    if new.status is distinct from old.status then
      if is_assigned or not (
        (old.status = 'submitted' and new.status in ('approved', 'declined')) or
        (old.status in ('approved', 'declined') and new.status = 'submitted'
          and old.withdrawal_requested_at is null) or
        (old.status = 'approved' and new.status = 'withdrawn'
          and old.withdrawal_requested_at is not null)
      ) then raise exception 'Invalid chair application decision'; end if;
      new.reviewed_at := case when new.status = 'submitted' then null
        when new.status = 'withdrawn' then old.reviewed_at else now() end;
    elsif new.reviewed_at is distinct from old.reviewed_at then
      raise exception 'Review time cannot be edited';
    end if;
    if new.withdrawal_requested_at is distinct from old.withdrawal_requested_at then
      raise exception 'The withdrawal request cannot be edited by the conference chair';
    end if;
    return new;
  end if;

  if new.user_id <> (select auth.uid()) or new.reviewed_at is distinct from old.reviewed_at then
    raise exception 'Only the applicant may edit their application';
  end if;
  if old.status = 'submitted' and new.status in ('submitted', 'withdrawn') and not is_assigned
    and (new.status = 'withdrawn' or app_private.chair_application_window_open(new.edition_year))
    and new.submitted_at is not distinct from old.submitted_at
    and new.withdrawal_requested_at is not distinct from old.withdrawal_requested_at then
    return new;
  end if;
  if old.status = 'withdrawn' and new.status = 'submitted'
    and app_private.chair_application_window_open(new.edition_year) and not is_assigned
    and new.withdrawal_requested_at is not distinct from old.withdrawal_requested_at then
    new.submitted_at := now();
    new.reviewed_at := null;
    new.withdrawal_requested_at := null;
    return new;
  end if;
  if old.status = 'approved' and new.status = 'withdrawn' and not is_assigned
    and new.preferred_types is not distinct from old.preferred_types
    and new.available_days is not distinct from old.available_days
    and new.submitted_at is not distinct from old.submitted_at
    and new.withdrawal_requested_at is not distinct from old.withdrawal_requested_at then
    return new;
  end if;
  if old.status = 'approved' and new.status = old.status and is_assigned
    and old.withdrawal_requested_at is null and new.withdrawal_requested_at is not null
    and new.preferred_types is not distinct from old.preferred_types
    and new.available_days is not distinct from old.available_days
    and new.submitted_at is not distinct from old.submitted_at then
    new.withdrawal_requested_at := now();
    return new;
  end if;
  raise exception 'This chair application can no longer be edited';
end;
$$;
revoke all on function app_private.guard_chair_application() from public;
create trigger guard_chair_application before insert or update
  on public.session_chair_applications for each row
  execute function app_private.guard_chair_application();

create function app_private.guard_chair_application_review() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not app_private.is_chair() or not exists (
    select 1 from public.session_chair_applications a
    join public.conference_editions e on e.year = a.edition_year
    where a.id = new.application_id and e.status = 'current'
  ) then raise exception 'Only the conference chair may review current applications'; end if;
  if tg_op = 'UPDATE' and new.application_id <> old.application_id then
    raise exception 'Review identity cannot be changed';
  end if;
  new.reviewed_by := (select auth.uid());
  new.updated_at := now();
  return new;
end;
$$;
revoke all on function app_private.guard_chair_application_review() from public;
create trigger guard_chair_application_review before insert or update
  on public.session_chair_application_reviews for each row
  execute function app_private.guard_chair_application_review();

create function app_private.require_approved_chair_applicant() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_year integer; v_type text; v_day date;
begin
  if tg_op = 'UPDATE' and new.user_id = old.user_id then return new; end if;
  select s.edition_year, s.session_type, (s.starts_at at time zone 'Asia/Seoul')::date
    into v_year, v_type, v_day from public.program_sessions s where s.id = new.session_id;
  if v_day is null or not exists (
    select 1 from public.session_chair_applications a
    where a.edition_year = v_year and a.user_id = new.user_id
      and a.status = 'approved' and a.withdrawal_requested_at is null
      and v_type = any(a.preferred_types) and v_day = any(a.available_days)
  ) then raise exception 'Assign an approved applicant available for this session'; end if;
  return new;
end;
$$;
revoke all on function app_private.require_approved_chair_applicant() from public;
create trigger require_approved_chair_applicant before insert or update
  on public.session_chairs for each row
  execute function app_private.require_approved_chair_applicant();

create function app_private.guard_chair_assignment_schedule() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (new.starts_at is distinct from old.starts_at
      or new.session_type is distinct from old.session_type) and exists (
    select 1 from public.session_chairs sc
    left join public.session_chair_applications a
      on a.edition_year = new.edition_year and a.user_id = sc.user_id
    where sc.session_id = new.id and (
      a.status <> 'approved'
      or new.starts_at is null
      or new.session_type <> all(a.preferred_types)
      or (new.starts_at at time zone 'Asia/Seoul')::date <> all(a.available_days)
    )
  ) then raise exception 'Reassign the session chair before changing the session schedule'; end if;
  return new;
end;
$$;
revoke all on function app_private.guard_chair_assignment_schedule() from public;
create trigger guard_chair_assignment_schedule before update on public.program_sessions
  for each row execute function app_private.guard_chair_assignment_schedule();

alter table public.session_chair_applications enable row level security;
alter table public.session_chair_application_reviews enable row level security;
create policy chair_applications_read on public.session_chair_applications
  for select to authenticated using (user_id = (select auth.uid()) or (select app_private.is_chair()));
create policy chair_applications_insert on public.session_chair_applications
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy chair_applications_update on public.session_chair_applications
  for update to authenticated
  using (user_id = (select auth.uid()) or (select app_private.is_chair()))
  with check (user_id = (select auth.uid()) or (select app_private.is_chair()));
create policy chair_application_reviews_read on public.session_chair_application_reviews
  for select to authenticated using ((select app_private.is_chair()));
create policy chair_application_reviews_insert on public.session_chair_application_reviews
  for insert to authenticated with check ((select app_private.is_chair()));
create policy chair_application_reviews_update on public.session_chair_application_reviews
  for update to authenticated using ((select app_private.is_chair()))
  with check ((select app_private.is_chair()));
grant select, insert, update on public.session_chair_applications,
  public.session_chair_application_reviews to authenticated;
