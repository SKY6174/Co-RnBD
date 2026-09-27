-- Co-R&BD is one conference. Keep applications separate from paper submissions.
alter table public.conference_settings
  add column registration_open boolean not null default false,
  add column registration_deadline timestamptz not null default '2026-10-30 18:00:00+09';

create table public.attendee_registrations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.profiles(user_id) on delete cascade,
  category text not null check (category in ('student', 'faculty', 'industry', 'other')),
  attendance_days date[] not null,
  status text not null default 'applied' check (status in ('applied', 'confirmed', 'cancelled')),
  checked_in_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint registration_days_valid check (
    cardinality(attendance_days) between 1 and 2
    and array_position(attendance_days, null) is null
    and attendance_days <@ array['2026-12-17'::date, '2026-12-18'::date]
    and (cardinality(attendance_days) = 1 or attendance_days[1] <> attendance_days[2])
  ),
  constraint checked_in_only_when_confirmed check (checked_in_at is null or status = 'confirmed')
);

create index attendee_registrations_status_idx on public.attendee_registrations(status);

create function app_private.guard_attendee_registration() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  is_chair_user boolean := app_private.is_chair();
  window_open boolean;
begin
  if tg_op = 'UPDATE' and (
    new.id <> old.id or new.user_id <> old.user_id
    or new.created_at is distinct from old.created_at
  ) then
    raise exception 'Registration owner cannot be changed';
  end if;
  if not is_chair_user then
    if new.user_id <> (select auth.uid()) then
      raise exception 'Registration owner must be the current user';
    end if;
    select registration_open and now() <= registration_deadline
      into window_open from public.conference_settings where id = true;
    if tg_op = 'INSERT' then
      if not coalesce(window_open, false) then raise exception 'Registration is closed'; end if;
      if new.status <> 'applied' or new.checked_in_at is not null then
        raise exception 'Only the chair may confirm or check in';
      end if;
      if not exists (
        select 1 from public.profiles
        where user_id = new.user_id
          and trim(full_name) <> '' and trim(affiliation) <> ''
      ) then raise exception 'Name and affiliation are required'; end if;
    else
      if new.checked_in_at is distinct from old.checked_in_at
        or new.status = 'confirmed'
        or (old.status = 'confirmed' and new.status <> 'cancelled') then
        raise exception 'Only the chair may confirm or check in';
      end if;
      if new.status = 'cancelled' and old.status <> 'cancelled' then
        if new.category is distinct from old.category
          or new.attendance_days is distinct from old.attendance_days then
          raise exception 'Cancel without changing registration details';
        end if;
      elsif not coalesce(window_open, false) then
        raise exception 'Registration is closed';
      end if;
      if new.status = 'applied' and not exists (
        select 1 from public.profiles
        where user_id = new.user_id
          and trim(full_name) <> '' and trim(affiliation) <> ''
      ) then raise exception 'Name and affiliation are required'; end if;
    end if;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger guard_attendee_registration
  before insert or update on public.attendee_registrations
  for each row execute function app_private.guard_attendee_registration();

create table public.program_speakers (
  id uuid primary key default gen_random_uuid(),
  full_name text not null check (char_length(trim(full_name)) between 1 and 120),
  affiliation text not null default '' check (char_length(affiliation) <= 200),
  bio text not null default '' check (char_length(bio) <= 1200),
  is_published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.program_sessions (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(trim(title)) between 2 and 200),
  session_type text not null check (session_type in ('keynote', 'oral', 'poster', 'panel', 'workshop', 'ceremony', 'networking', 'break', 'other')),
  starts_at timestamptz,
  ends_at timestamptz,
  room text not null default '' check (char_length(room) <= 120),
  description text not null default '' check (char_length(description) <= 1500),
  moderator text not null default '' check (char_length(moderator) <= 120),
  is_published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint session_time_valid check (
    (starts_at is null and ends_at is null) or
    (starts_at is not null and ends_at is not null and starts_at < ends_at
      and (starts_at at time zone 'Asia/Seoul')::date in ('2026-12-17'::date, '2026-12-18'::date)
      and (ends_at at time zone 'Asia/Seoul')::date in ('2026-12-17'::date, '2026-12-18'::date))
  ),
  constraint published_session_scheduled check (
    not is_published or (starts_at is not null and ends_at is not null and trim(room) <> '')
  )
);
create index program_sessions_public_order_idx on public.program_sessions(is_published, starts_at);

create table public.program_session_speakers (
  session_id uuid not null references public.program_sessions(id) on delete cascade,
  speaker_id uuid not null references public.program_speakers(id) on delete cascade,
  sort_order smallint not null default 1 check (sort_order between 1 and 30),
  primary key (session_id, speaker_id),
  unique (session_id, sort_order)
);
create index program_session_speakers_speaker_idx on public.program_session_speakers(speaker_id);

create function app_private.touch_program_row() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
create trigger touch_program_speakers before update on public.program_speakers
  for each row execute function app_private.touch_program_row();
create trigger touch_program_sessions before update on public.program_sessions
  for each row execute function app_private.touch_program_row();

alter table public.attendee_registrations enable row level security;
alter table public.program_speakers enable row level security;
alter table public.program_sessions enable row level security;
alter table public.program_session_speakers enable row level security;

-- The chair helper returns false without an authenticated user. Anonymous
-- readers need EXECUTE because public program policies also reference it.
grant usage on schema app_private to anon;
grant execute on function app_private.is_chair() to anon;

create policy registrations_read on public.attendee_registrations for select to authenticated
  using (user_id = (select auth.uid()) or (select app_private.is_chair()));
create policy registrations_insert on public.attendee_registrations for insert to authenticated
  with check (user_id = (select auth.uid()) and status = 'applied');
create policy registrations_update on public.attendee_registrations for update to authenticated
  using (user_id = (select auth.uid()) or (select app_private.is_chair()))
  with check (user_id = (select auth.uid()) or (select app_private.is_chair()));

create policy speakers_read on public.program_speakers for select to anon, authenticated
  using (is_published or (select app_private.is_chair()));
create policy speakers_insert on public.program_speakers for insert to authenticated
  with check ((select app_private.is_chair()));
create policy speakers_update on public.program_speakers for update to authenticated
  using ((select app_private.is_chair())) with check ((select app_private.is_chair()));
create policy speakers_delete on public.program_speakers for delete to authenticated
  using ((select app_private.is_chair()));

create policy sessions_read on public.program_sessions for select to anon, authenticated
  using (is_published or (select app_private.is_chair()));
create policy sessions_insert on public.program_sessions for insert to authenticated
  with check ((select app_private.is_chair()));
create policy sessions_update on public.program_sessions for update to authenticated
  using ((select app_private.is_chair())) with check ((select app_private.is_chair()));
create policy sessions_delete on public.program_sessions for delete to authenticated
  using ((select app_private.is_chair()));

create policy session_speakers_read on public.program_session_speakers for select to anon, authenticated
  using ((select app_private.is_chair()) or (
    exists (select 1 from public.program_sessions s where s.id = session_id and s.is_published)
    and exists (select 1 from public.program_speakers p where p.id = speaker_id and p.is_published)
  ));
create policy session_speakers_insert on public.program_session_speakers for insert to authenticated
  with check ((select app_private.is_chair()));
create policy session_speakers_update on public.program_session_speakers for update to authenticated
  using ((select app_private.is_chair())) with check ((select app_private.is_chair()));
create policy session_speakers_delete on public.program_session_speakers for delete to authenticated
  using ((select app_private.is_chair()));

grant select, insert, update on public.attendee_registrations to authenticated;
grant select on public.program_speakers, public.program_sessions, public.program_session_speakers to anon, authenticated;
grant insert, update, delete on public.program_speakers, public.program_sessions, public.program_session_speakers to authenticated;
