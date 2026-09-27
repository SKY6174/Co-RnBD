-- Annual editions keep operational records separate without copying the site or auth users.
create table public.conference_editions (
  year integer primary key check (year between 2026 and 2100),
  title text not null check (char_length(btrim(title)) between 5 and 160),
  start_date date,
  end_date date,
  venue text not null default '' check (char_length(venue) <= 240),
  summary text not null default '' check (char_length(summary) <= 2000),
  proceedings_url text check (proceedings_url is null or (char_length(proceedings_url) <= 500 and proceedings_url ~ '^https://[^[:space:]]+$')),
  status text not null default 'draft' check (status in ('draft', 'current', 'archived')),
  archive_published boolean not null default false,
  created_at timestamptz not null default now(),
  constraint edition_dates check (
    (start_date is null and end_date is null) or
    (start_date is not null and end_date is not null and start_date <= end_date
      and end_date - start_date < 7
      and extract(year from start_date) = year and extract(year from end_date) = year)
  ),
  constraint archive_only_when_archived check (not archive_published or status = 'archived')
);
create unique index conference_editions_one_current on public.conference_editions ((status)) where status = 'current';
insert into public.conference_editions (year, title, start_date, end_date, venue, status)
values (2026, 'Co-R&BD Conference 2026', '2026-12-17', '2026-12-18', '울산과학대학교 동부캠퍼스', 'current');

create function app_private.current_edition_year() returns integer
language sql stable security definer set search_path = '' as $$
  select year from public.conference_editions where status = 'current';
$$;
revoke all on function app_private.current_edition_year() from public;
grant execute on function app_private.current_edition_year() to anon, authenticated;

alter table public.conference_settings
  add column edition_year integer not null default 2026 references public.conference_editions(year);
alter table public.conference_settings drop constraint conference_settings_pkey;
alter table public.conference_settings drop column id;
alter table public.conference_settings add primary key (edition_year);
alter table public.conference_settings alter column edition_year set default app_private.current_edition_year();
alter table public.conference_settings alter column registration_deadline drop not null;
alter table public.conference_settings add constraint registration_window_has_deadline
  check (not registration_open or registration_deadline is not null);

alter table public.papers add column edition_year integer not null default 2026 references public.conference_editions(year);
alter table public.papers alter column edition_year set default app_private.current_edition_year();
create index papers_edition_status_idx on public.papers (edition_year, status);
alter table public.attendee_registrations add column edition_year integer not null default 2026 references public.conference_editions(year);
alter table public.attendee_registrations alter column edition_year set default app_private.current_edition_year();
alter table public.attendee_registrations drop constraint attendee_registrations_user_id_key;
alter table public.attendee_registrations add unique (edition_year, user_id);
alter table public.attendee_registrations drop constraint registration_days_valid;
alter table public.attendee_registrations add constraint registration_days_valid check (
  cardinality(attendance_days) between 1 and 7 and array_position(attendance_days, null) is null
);
alter table public.program_speakers add column edition_year integer not null default 2026 references public.conference_editions(year);
alter table public.program_speakers alter column edition_year set default app_private.current_edition_year();
create index program_speakers_edition_idx on public.program_speakers (edition_year);
alter table public.program_sessions add column edition_year integer not null default 2026 references public.conference_editions(year);
alter table public.program_sessions alter column edition_year set default app_private.current_edition_year();
create index program_sessions_edition_order_idx on public.program_sessions (edition_year, starts_at);
alter table public.program_sessions drop constraint session_time_valid;
alter table public.program_sessions add constraint session_time_valid check (
  (starts_at is null and ends_at is null) or
  (starts_at is not null and ends_at is not null and starts_at < ends_at)
);

create function app_private.guard_current_edition_row() returns trigger
language plpgsql security definer set search_path = '' as $$
declare target_year integer;
begin
  target_year := case when tg_op = 'DELETE' then old.edition_year else new.edition_year end;
  if tg_op = 'UPDATE' and new.edition_year <> old.edition_year then
    raise exception 'Conference year cannot be changed';
  end if;
  if tg_op = 'INSERT' and tg_table_name = 'conference_settings'
    and app_private.is_chair() and exists (
      select 1 from public.conference_editions where year = target_year and status = 'draft'
    ) then return new; end if;
  if not exists (select 1 from public.conference_editions where year = target_year and status = 'current') then
    raise exception 'Only the current conference may be changed';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function app_private.guard_current_edition_row() from public;
create trigger annual_settings before insert or update or delete on public.conference_settings
  for each row execute function app_private.guard_current_edition_row();
create trigger annual_papers before insert or update or delete on public.papers
  for each row execute function app_private.guard_current_edition_row();
create trigger annual_registrations before insert or update or delete on public.attendee_registrations
  for each row execute function app_private.guard_current_edition_row();
create trigger annual_speakers before insert or update or delete on public.program_speakers
  for each row execute function app_private.guard_current_edition_row();
create trigger annual_sessions before insert or update or delete on public.program_sessions
  for each row execute function app_private.guard_current_edition_row();

create function app_private.guard_current_paper_child() returns trigger
language plpgsql security definer set search_path = '' as $$
declare target_paper uuid;
begin
  target_paper := case when tg_op = 'DELETE' then old.paper_id else new.paper_id end;
  if tg_op = 'UPDATE' and new.paper_id <> old.paper_id then raise exception 'Paper cannot be changed'; end if;
  if not exists (
    select 1 from public.papers p join public.conference_editions e on e.year = p.edition_year
    where p.id = target_paper and e.status = 'current'
  ) then raise exception 'Archived conference papers are read only'; end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function app_private.guard_current_paper_child() from public;
create trigger annual_authors before insert or update or delete on public.paper_authors
  for each row execute function app_private.guard_current_paper_child();
create trigger annual_files before insert or update or delete on public.paper_files
  for each row execute function app_private.guard_current_paper_child();
create trigger annual_reviews before insert or update or delete on public.reviews
  for each row execute function app_private.guard_current_paper_child();

create function app_private.guard_session_speaker_year() returns trigger
language plpgsql security definer set search_path = '' as $$
declare session_year integer; speaker_year integer;
begin
  select edition_year into session_year from public.program_sessions
    where id = case when tg_op = 'DELETE' then old.session_id else new.session_id end;
  if tg_op <> 'DELETE' then
    select edition_year into speaker_year from public.program_speakers where id = new.speaker_id;
    if session_year is distinct from speaker_year then raise exception 'Speaker and session must belong to the same conference'; end if;
  end if;
  if not exists (select 1 from public.conference_editions where year = session_year and status = 'current') then
    raise exception 'Archived conference program is read only';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function app_private.guard_session_speaker_year() from public;
create trigger annual_session_speakers before insert or update or delete on public.program_session_speakers
  for each row execute function app_private.guard_session_speaker_year();

-- Replace the fixed 2026 date rules with the edition's confirmed dates.
create or replace function app_private.guard_attendee_registration() returns trigger
language plpgsql security definer set search_path = '' as $$
declare is_chair_user boolean := app_private.is_chair();
declare window_open boolean;
declare event_start date;
declare event_end date;
begin
  if tg_op = 'UPDATE' and (
    new.id <> old.id or new.user_id <> old.user_id or new.edition_year <> old.edition_year
    or new.created_at is distinct from old.created_at
  ) then raise exception 'Registration owner and conference cannot be changed'; end if;
  select s.registration_open and now() <= s.registration_deadline, e.start_date, e.end_date
    into window_open, event_start, event_end
    from public.conference_settings s join public.conference_editions e on e.year = s.edition_year
    where s.edition_year = new.edition_year and e.status = 'current';
  if event_start is null or event_end is null or exists (
    select 1 from unnest(new.attendance_days) day where day < event_start or day > event_end
  ) or (select count(distinct day) from unnest(new.attendance_days) day) <> cardinality(new.attendance_days)
  then raise exception 'Attendance days must be unique dates within the conference'; end if;
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

create function app_private.guard_session_dates() returns trigger
language plpgsql security definer set search_path = '' as $$
declare event_start date; event_end date;
begin
  if new.starts_at is not null then
    select start_date, end_date into event_start, event_end from public.conference_editions where year = new.edition_year;
    if event_start is null or (new.starts_at at time zone 'Asia/Seoul')::date < event_start
      or (new.ends_at at time zone 'Asia/Seoul')::date > event_end
    then raise exception 'Session must be scheduled within the conference dates'; end if;
  end if;
  return new;
end;
$$;
revoke all on function app_private.guard_session_dates() from public;
create trigger annual_session_dates before insert or update on public.program_sessions
  for each row execute function app_private.guard_session_dates();

drop policy papers_insert on public.papers;
create policy papers_insert on public.papers for insert to authenticated with check (
  owner_id = (select auth.uid()) and status = 'draft' and decision_note = ''
  and final_presentation is null and submitted_at is null and decided_at is null
  and edition_year = (select app_private.current_edition_year())
  and exists (
    select 1 from public.conference_settings s where s.edition_year = papers.edition_year
      and s.submissions_open and (s.submission_deadline is null or now() <= s.submission_deadline)
  )
);
create or replace function app_private.guard_paper_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not app_private.is_chair() then
    if new.id <> old.id or new.created_at is distinct from old.created_at or new.owner_id <> old.owner_id
      or new.edition_year <> old.edition_year or new.decision_note <> old.decision_note
      or new.final_presentation is distinct from old.final_presentation
      or new.decided_at is distinct from old.decided_at
      or (new.status <> 'submitted' and new.submitted_at is distinct from old.submitted_at)
    then raise exception 'Only chairs may change identity or decision fields'; end if;
    if old.status not in ('draft', 'revision') or new.status not in ('draft', 'submitted')
    then raise exception 'Paper is not editable'; end if;
  end if;
  if new.status = 'submitted' and old.status <> 'submitted' then
    if not app_private.is_chair() and old.status <> 'revision' and not exists (
      select 1 from public.conference_settings s where s.edition_year = new.edition_year
        and s.submissions_open and (s.submission_deadline is null or now() <= s.submission_deadline)
    ) then raise exception 'Submissions are not open'; end if;
    if not exists (select 1 from public.paper_authors where paper_id = new.id)
    then raise exception 'At least one author is required'; end if;
    if not exists (select 1 from public.paper_files where paper_id = new.id and file_stage = 'submission')
    then raise exception 'A submission PDF is required'; end if;
    new.submitted_at := now();
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create or replace function app_private.guard_review_update() returns trigger
language plpgsql set search_path = '' as $$
declare review_year integer;
begin
  if new.id <> old.id or new.paper_id <> old.paper_id or new.reviewer_id <> old.reviewer_id
    or new.assigned_at is distinct from old.assigned_at then raise exception 'Review assignment cannot be changed'; end if;
  if old.review_state = 'declined' then raise exception 'Declined review assignments cannot be edited'; end if;
  if old.review_state = 'submitted' and new.review_state in ('assigned', 'draft')
    then raise exception 'Submitted reviews cannot return to draft'; end if;
  if new.review_state = 'declined' then
    if btrim(new.decline_reason) = '' then raise exception 'A conflict reason is required'; end if;
    new.recommendation := null; new.comments := ''; new.conflict_confirmed := false;
    new.submitted_at := null; new.declined_at := now();
  else
    select edition_year into review_year from public.papers where id = new.paper_id;
    if not exists (
      select 1 from public.conference_settings s where s.edition_year = review_year
        and s.reviews_open and (s.review_deadline is null or now() <= s.review_deadline)
    ) then raise exception 'Review submission is closed'; end if;
    if new.decline_reason <> '' then raise exception 'Conflict reasons are only for declined assignments'; end if;
    new.declined_at := null;
    if new.review_state = 'submitted' then
      if new.recommendation is null or btrim(new.comments) = '' or not new.conflict_confirmed
      then raise exception 'Recommendation, comment and conflict confirmation are required'; end if;
      new.submitted_at := now();
    else
      if new.recommendation is not null then raise exception 'Recommendations must be submitted'; end if;
      new.submitted_at := null;
    end if;
  end if;
  return new;
end;
$$;
drop policy files_insert on public.paper_files;
create policy files_insert on public.paper_files for insert to authenticated with check (
  uploaded_by = (select auth.uid()) and split_part(storage_path, '/', 1) = (select auth.uid())::text
  and split_part(storage_path, '/', 2) = paper_id::text
  and exists (
    select 1 from public.papers p join public.conference_editions e on e.year = p.edition_year
    where p.id = paper_id and e.status = 'current' and p.owner_id = (select auth.uid())
      and ((file_stage = 'submission' and p.status in ('draft', 'revision'))
        or (file_stage = 'final' and p.status = 'accepted' and exists (
          select 1 from public.conference_settings s where s.edition_year = p.edition_year
            and s.final_uploads_open and (s.final_deadline is null or now() <= s.final_deadline)
        )))
  )
);
drop policy paper_storage_insert on storage.objects;
create policy paper_storage_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'paper-pdfs' and (storage.foldername(name))[1] = (select auth.uid())::text
  and exists (
    select 1 from public.papers p join public.conference_editions e on e.year = p.edition_year
    where p.id::text = (storage.foldername(name))[2] and p.owner_id = (select auth.uid())
      and e.status = 'current' and
      (p.status in ('draft', 'revision') or (p.status = 'accepted' and exists (
        select 1 from public.conference_settings s where s.edition_year = p.edition_year
          and s.final_uploads_open and (s.final_deadline is null or now() <= s.final_deadline)
      )))
  )
);

drop policy speakers_read on public.program_speakers;
create policy speakers_read on public.program_speakers for select to anon, authenticated using (
  (select app_private.is_chair()) or (is_published and exists (
    select 1 from public.conference_editions e where e.year = edition_year
      and (e.status = 'current' or (e.status = 'archived' and e.archive_published))
  ))
);
drop policy sessions_read on public.program_sessions;
create policy sessions_read on public.program_sessions for select to anon, authenticated using (
  (select app_private.is_chair()) or (is_published and exists (
    select 1 from public.conference_editions e where e.year = edition_year
      and (e.status = 'current' or (e.status = 'archived' and e.archive_published))
  ))
);

create function app_private.check_edition_edit() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.year <> old.year or new.created_at is distinct from old.created_at then
    raise exception 'Conference identity cannot be changed';
  end if;
  if old.status = 'archived' and (
    new.title is distinct from old.title or new.start_date is distinct from old.start_date
    or new.end_date is distinct from old.end_date or new.venue is distinct from old.venue
    or new.status is distinct from old.status
  ) then raise exception 'Archived conference facts are frozen'; end if;
  return new;
end;
$$;
revoke all on function app_private.check_edition_edit() from public;
create trigger check_edition_edit before update on public.conference_editions
  for each row execute function app_private.check_edition_edit();

alter table public.conference_editions enable row level security;
create policy editions_read on public.conference_editions for select to anon, authenticated using (
  status = 'current' or (status = 'archived' and archive_published) or (select app_private.is_chair())
);
create policy editions_update on public.conference_editions for update to authenticated
  using ((select app_private.is_chair())) with check ((select app_private.is_chair()));
grant select on public.conference_editions to anon, authenticated;
grant update (title, start_date, end_date, venue, summary, proceedings_url, archive_published)
  on public.conference_editions to authenticated;
drop policy settings_read on public.conference_settings;
create policy settings_read on public.conference_settings for select to anon, authenticated
  using (edition_year = (select app_private.current_edition_year()) or (select app_private.is_chair()));
drop policy settings_chair on public.conference_settings;
create policy settings_chair on public.conference_settings for update to authenticated
  using ((select app_private.is_chair()) and edition_year = (select app_private.current_edition_year()))
  with check ((select app_private.is_chair()) and edition_year = (select app_private.current_edition_year()));

-- SECURITY DEFINER is limited to a checked chair and a fixed, narrow operation.
create function public.create_conference_edition(p_year integer) returns integer
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not app_private.is_chair() then raise exception 'Chair access required'; end if;
  if p_year <= (select app_private.current_edition_year()) or p_year > 2100
  then raise exception 'Choose a later conference year'; end if;
  insert into public.conference_editions (year, title)
    values (p_year, 'Co-R&BD Conference ' || p_year);
  insert into public.conference_settings (edition_year, submissions_open, reviews_open,
    final_uploads_open, registration_open, registration_deadline)
    values (p_year, false, false, false, false, null);
  return p_year;
end;
$$;
revoke all on function public.create_conference_edition(integer) from public;
grant execute on function public.create_conference_edition(integer) to authenticated;

create function public.activate_conference_edition(p_year integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare previous_year integer;
begin
  if (select auth.uid()) is null or not app_private.is_chair() then raise exception 'Chair access required'; end if;
  perform pg_advisory_xact_lock(2026, 1);
  select year into previous_year from public.conference_editions where status = 'current' for update;
  if previous_year is null then raise exception 'Current conference is missing'; end if;
  if not exists (
    select 1 from public.conference_editions where year = p_year and status = 'draft'
      and start_date is not null and end_date is not null
  ) then raise exception 'Target draft needs confirmed event dates'; end if;
  if not exists (
    select 1 from public.conference_editions where year = previous_year and end_date < current_date
  ) then raise exception 'The current conference has not ended'; end if;
  update public.conference_settings
    set submissions_open = false, reviews_open = false, final_uploads_open = false, registration_open = false
    where edition_year = previous_year;
  update public.conference_editions set status = 'archived' where year = previous_year;
  update public.conference_editions set status = 'current' where year = p_year;
  return p_year;
end;
$$;
revoke all on function public.activate_conference_edition(integer) from public;
grant execute on function public.activate_conference_edition(integer) to authenticated;
