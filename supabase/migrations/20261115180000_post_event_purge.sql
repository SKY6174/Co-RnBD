-- Post-event destruction of the remaining personal data of a finished edition
-- (privacy policy section 4). Run by a database administrator AFTER
-- app_private.archive_and_purge_registrations(year, ...).
-- Operator decisions (2026-11-15):
--   * accepted papers whose authors consented to publication are kept for the
--     proceedings as title, track, author names/affiliations and the final PDF;
--   * accounts with a staff role are kept;
--   * published program speakers and sessions are kept for the public archive.
-- PDFs in Storage are removed afterwards with scripts/purge-paper-pdfs.py, using
-- app_private.paper_pdf_paths_to_purge() (Storage rows cannot be deleted in SQL).

create table app_private.proceedings_archive (
  id uuid primary key default gen_random_uuid(),
  edition_year integer not null,
  source_paper_id uuid not null unique,
  title text not null,
  track text not null,
  paper_type text,
  final_presentation text,
  assigned_session text,
  authors jsonb not null,
  final_file_path text not null unique,
  final_file_name text not null,
  final_file_version integer not null,
  consented_at timestamptz not null,
  archived_at timestamptz not null default now()
);
comment on table app_private.proceedings_archive is
  'Consented accepted papers kept for the proceedings after the edition purge. No link to accounts.';
alter table app_private.proceedings_archive enable row level security;
revoke all on app_private.proceedings_archive from public, anon, authenticated, service_role;

-- Marks the single transaction allowed to delete rows of a finished edition.
create table app_private.edition_purge_context (
  tx_id xid8 primary key,
  edition_year integer not null
);
alter table app_private.edition_purge_context enable row level security;
revoke all on app_private.edition_purge_context from public, anon, authenticated, service_role;

create function app_private.in_edition_purge() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from app_private.edition_purge_context where tx_id = pg_current_xact_id());
$$;
revoke all on function app_private.in_edition_purge() from public, anon, authenticated, service_role;

-- Existing guards, unchanged except for the purge-transaction exception on DELETE.
create or replace function app_private.guard_current_edition_row() returns trigger
language plpgsql security definer set search_path = '' as $$
declare target_year integer;
begin
  target_year := case when tg_op = 'DELETE' then old.edition_year else new.edition_year end;
  if tg_op = 'DELETE' and tg_table_name = 'attendee_registrations' and exists (
    select 1 from app_private.registration_purge_context c
    where c.tx_id = pg_current_xact_id() and c.edition_year = target_year
  ) then return old; end if;
  if tg_op = 'DELETE' and exists (
    select 1 from app_private.edition_purge_context c
    where c.tx_id = pg_current_xact_id() and c.edition_year = target_year
  ) then return old; end if;
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

create or replace function app_private.guard_current_paper_child() returns trigger
language plpgsql security definer set search_path = '' as $$
declare target_paper uuid;
begin
  if tg_op = 'DELETE' and app_private.in_edition_purge() then return old; end if;
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

create or replace function app_private.guard_session_speaker_year() returns trigger
language plpgsql security definer set search_path = '' as $$
declare session_year integer; speaker_year integer;
begin
  if tg_op = 'DELETE' and app_private.in_edition_purge() then return old; end if;
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

create or replace function app_private.guard_session_chair_delete() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if app_private.in_edition_purge() then return old; end if;
  if old.report_submitted_at is not null then
    raise exception 'Reopen the submitted report before removing the session chair';
  end if;
  return old;
end;
$$;

create or replace function app_private.guard_session_presentation_delete() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if app_private.in_edition_purge() then return old; end if;
  if exists (select 1 from public.session_chairs
    where session_id = old.session_id and report_submitted_at is not null) then
    raise exception 'Reopen the submitted report before removing a presentation';
  end if;
  return old;
end;
$$;

-- Papers kept for the proceedings: accepted, consented, with a final PDF.
create function app_private.proceedings_candidates(p_year integer)
returns table (paper_id uuid, final_file_id uuid)
language sql stable set search_path = '' as $$
  select p.id, f.id
  from public.papers p
  join public.paper_publication_consents c on c.paper_id = p.id and c.consented
  join lateral (
    select pf.id from public.paper_files pf
    where pf.paper_id = p.id and pf.file_stage = 'final'
    order by pf.version desc limit 1
  ) f on true
  where p.edition_year = p_year and p.status = 'accepted';
$$;

-- Accounts eligible for deletion: no staff role and no sign-in or creation after
-- the day following the event (KST), so accounts used for a later edition are kept.
create function app_private.purgeable_accounts(p_year integer) returns setof uuid
language sql stable security definer set search_path = '' as $$
  select u.id from auth.users u, public.conference_editions e
  where e.year = p_year and e.end_date is not null
    and not exists (select 1 from public.staff_roles s where s.user_id = u.id)
    -- a profile delete would cascade into another edition's registration
    and not exists (select 1 from public.attendee_registrations r where r.user_id = u.id)
    and greatest(u.created_at, coalesce(u.last_sign_in_at, u.created_at))
      < ((e.end_date + 1)::timestamp at time zone 'Asia/Seoul');
$$;

create function app_private.preview_edition_purge(p_year integer) returns jsonb
language plpgsql stable set search_path = '' as $$
declare e public.conference_editions; paper_ids uuid[];
begin
  select * into e from public.conference_editions where year = p_year;
  if not found then raise exception 'Unknown conference year %', p_year; end if;
  select coalesce(array_agg(id), '{}') into paper_ids from public.papers where edition_year = p_year;
  return jsonb_build_object(
    'edition_year', p_year,
    'edition_status', e.status,
    'purge_allowed_from', e.end_date + 1,
    'registrations_remaining', (select count(*) from public.attendee_registrations where edition_year = p_year),
    'papers_to_delete', cardinality(paper_ids),
    'papers_kept_for_proceedings', (select count(*) from app_private.proceedings_candidates(p_year)),
    'accepted_without_consent', (select count(*) from public.papers p where p.edition_year = p_year and p.status = 'accepted'
      and not exists (select 1 from app_private.proceedings_candidates(p_year) c where c.paper_id = p.id)),
    'reviews_to_delete', (select count(*) from public.reviews where paper_id = any(paper_ids)),
    'email_outbox_to_delete', (select count(*) from app_private.review_email_outbox where paper_id = any(paper_ids) or paper_id is null),
    'committee_rows_to_delete', (select count(*) from public.review_committee where edition_year = p_year),
    'unpublished_speakers_to_delete', (select count(*) from public.program_speakers where edition_year = p_year and not is_published),
    'unpublished_sessions_to_delete', (select count(*) from public.program_sessions where edition_year = p_year and not is_published),
    'session_chairs_to_delete', (select count(*) from public.session_chairs c join public.program_sessions s on s.id = c.session_id where s.edition_year = p_year),
    'accounts_to_delete_at_most', (select count(*) from app_private.purgeable_accounts(p_year)),
    'staff_accounts_kept', (select count(*) from public.staff_roles),
    'confirmation_text', format('PURGE EDITION %s', p_year)
  );
end;
$$;

create function app_private.purge_edition_personal_data(p_year integer, p_confirmation text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  e public.conference_editions;
  today date := (now() at time zone 'Asia/Seoul')::date;
  paper_ids uuid[]; account uuid;
  n_archived integer; n_outbox integer; n_presentations integer; n_chairs integer;
  n_sessions integer; n_speakers integer; n_papers integer; n_committee integer;
  n_accounts integer := 0; n_accounts_kept integer := 0;
begin
  if p_confirmation is distinct from format('PURGE EDITION %s', p_year) then
    raise exception 'Confirmation text must be exactly: PURGE EDITION %', p_year;
  end if;
  select * into e from public.conference_editions where year = p_year for update;
  if not found then raise exception 'Unknown conference year %', p_year; end if;
  if e.end_date is null or today <= e.end_date then
    raise exception 'The edition can be purged only after the conference ends (end date %)', e.end_date;
  end if;
  if exists (select 1 from public.attendee_registrations where edition_year = p_year) then
    raise exception 'Run app_private.archive_and_purge_registrations for % first', p_year;
  end if;

  perform 1 from public.papers where edition_year = p_year for update;
  select coalesce(array_agg(id), '{}') into paper_ids from public.papers where edition_year = p_year;

  insert into app_private.proceedings_archive (edition_year, source_paper_id, title, track, paper_type,
    final_presentation, assigned_session, authors, final_file_path, final_file_name, final_file_version, consented_at)
  select p.edition_year, p.id, p.title, p.track, p.paper_type, p.final_presentation, p.assigned_session,
    coalesce((select jsonb_agg(jsonb_build_object('name', a.full_name, 'affiliation', a.affiliation) order by a.sort_order)
      from public.paper_authors a where a.paper_id = p.id), '[]'::jsonb),
    f.storage_path, f.original_name, f.version, c.decided_at
  from app_private.proceedings_candidates(p_year) k
  join public.papers p on p.id = k.paper_id
  join public.paper_files f on f.id = k.final_file_id
  join public.paper_publication_consents c on c.paper_id = p.id
  on conflict (source_paper_id) do nothing;
  get diagnostics n_archived = row_count;
  if exists (select 1 from app_private.proceedings_candidates(p_year) k
    where not exists (select 1 from app_private.proceedings_archive a where a.source_paper_id = k.paper_id)) then
    raise exception 'Proceedings archive verification failed';
  end if;

  insert into app_private.edition_purge_context (tx_id, edition_year) values (pg_current_xact_id(), p_year);

  delete from app_private.review_email_outbox where paper_id = any(paper_ids) or paper_id is null;
  get diagnostics n_outbox = row_count;
  delete from public.session_presentations sp using public.program_sessions s
    where sp.session_id = s.id and (s.edition_year = p_year or sp.paper_id = any(paper_ids));
  get diagnostics n_presentations = row_count;
  delete from public.session_chairs c using public.program_sessions s where c.session_id = s.id and s.edition_year = p_year;
  get diagnostics n_chairs = row_count;
  delete from public.program_sessions where edition_year = p_year and not is_published;
  get diagnostics n_sessions = row_count;
  delete from public.program_session_speakers ss using public.program_speakers sp
    where ss.speaker_id = sp.id and sp.edition_year = p_year and not sp.is_published;
  delete from public.program_speakers where edition_year = p_year and not is_published;
  get diagnostics n_speakers = row_count;

  delete from public.paper_publication_consents where paper_id = any(paper_ids);
  delete from public.paper_final_checks where paper_id = any(paper_ids);
  delete from public.paper_events where paper_id = any(paper_ids);
  delete from public.reviews where paper_id = any(paper_ids);
  delete from public.paper_files where paper_id = any(paper_ids);
  delete from public.paper_authors where paper_id = any(paper_ids);
  delete from public.papers where id = any(paper_ids);
  get diagnostics n_papers = row_count;
  delete from public.review_committee where edition_year = p_year;
  get diagnostics n_committee = row_count;

  -- Delete each eligible account; one still referenced by another edition's data is kept.
  for account in select * from app_private.purgeable_accounts(p_year) loop
    begin
      delete from auth.users where id = account;
      n_accounts := n_accounts + 1;
    exception when foreign_key_violation then
      n_accounts_kept := n_accounts_kept + 1;
    end;
  end loop;

  delete from app_private.edition_purge_context where tx_id = pg_current_xact_id();
  return jsonb_build_object(
    'edition_year', p_year,
    'papers_kept_for_proceedings', n_archived,
    'papers_deleted', n_papers,
    'email_outbox_deleted', n_outbox,
    'session_presentations_deleted', n_presentations,
    'session_chairs_deleted', n_chairs,
    'unpublished_sessions_deleted', n_sessions,
    'unpublished_speakers_deleted', n_speakers,
    'committee_rows_deleted', n_committee,
    'accounts_deleted', n_accounts,
    'accounts_kept_with_other_data', n_accounts_kept,
    'next_step', 'Run scripts/purge-paper-pdfs.py to delete the PDFs listed by app_private.paper_pdf_paths_to_purge()'
  );
end;
$$;

-- PDFs whose paper no longer exists and that are not a kept proceedings file.
create function app_private.paper_pdf_paths_to_purge() returns table (path text)
language sql stable security definer set search_path = '' as $$
  select o.name from storage.objects o
  where o.bucket_id = 'paper-pdfs'
    and not exists (select 1 from public.papers p where p.id::text = split_part(o.name, '/', 2))
    and not exists (select 1 from app_private.proceedings_archive a where a.final_file_path = o.name)
  order by o.name;
$$;

revoke all on function app_private.proceedings_candidates(integer) from public, anon, authenticated, service_role;
revoke all on function app_private.purgeable_accounts(integer) from public, anon, authenticated, service_role;
revoke all on function app_private.preview_edition_purge(integer) from public, anon, authenticated, service_role;
revoke all on function app_private.purge_edition_personal_data(integer, text) from public, anon, authenticated, service_role;
revoke all on function app_private.paper_pdf_paths_to_purge() from public, anon, authenticated, service_role;
