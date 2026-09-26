-- Keep one small-conference workflow while enforcing each writable phase in Postgres.
alter table public.conference_settings
  add column submission_deadline timestamptz,
  add column reviews_open boolean not null default false,
  add column review_deadline timestamptz,
  add column final_uploads_open boolean not null default false,
  add column final_deadline timestamptz;

alter table public.paper_files
  add column file_stage text not null default 'submission'
    check (file_stage in ('submission', 'final'));

drop policy papers_insert on public.papers;
create policy papers_insert on public.papers for insert to authenticated with check (
  owner_id = (select auth.uid())
  and status = 'draft'
  and decision_note = ''
  and final_presentation is null
  and submitted_at is null
  and decided_at is null
  and exists (
    select 1 from public.conference_settings
    where submissions_open and (submission_deadline is null or now() <= submission_deadline)
  )
);

create or replace function app_private.guard_paper_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not app_private.is_chair() then
    if new.id <> old.id
      or new.created_at is distinct from old.created_at
      or new.owner_id <> old.owner_id
      or new.decision_note <> old.decision_note
      or new.final_presentation is distinct from old.final_presentation
      or new.decided_at is distinct from old.decided_at
      or (new.status <> 'submitted' and new.submitted_at is distinct from old.submitted_at) then
      raise exception 'Only chairs may change identity or decision fields';
    end if;
    if old.status not in ('draft', 'revision') or new.status not in ('draft', 'submitted') then
      raise exception 'Paper is not editable';
    end if;
  end if;
  if new.status = 'submitted' and old.status <> 'submitted' then
    if not app_private.is_chair() and old.status <> 'revision' and not exists (
      select 1 from public.conference_settings
      where submissions_open and (submission_deadline is null or now() <= submission_deadline)
    ) then
      raise exception 'Submissions are not open';
    end if;
    if not exists (
      select 1 from public.paper_files
      where paper_id = new.id and file_stage = 'submission'
    ) then
      raise exception 'A submission PDF is required';
    end if;
    new.submitted_at := now();
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create or replace function app_private.guard_review_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.id <> old.id or new.paper_id <> old.paper_id
    or new.reviewer_id <> old.reviewer_id
    or new.assigned_at is distinct from old.assigned_at then
    raise exception 'Review assignment cannot be changed';
  end if;
  if old.review_state = 'declined' then
    raise exception 'Declined review assignments cannot be edited';
  end if;
  if old.review_state = 'submitted' and new.review_state in ('assigned', 'draft') then
    raise exception 'Submitted reviews cannot return to draft';
  end if;
  if new.review_state = 'declined' then
    if btrim(new.decline_reason) = '' then
      raise exception 'A conflict reason is required';
    end if;
    new.recommendation := null;
    new.comments := '';
    new.conflict_confirmed := false;
    new.submitted_at := null;
    new.declined_at := now();
  else
    if not exists (
      select 1 from public.conference_settings
      where reviews_open and (review_deadline is null or now() <= review_deadline)
    ) then
      raise exception 'Review submission is closed';
    end if;
    if new.decline_reason <> '' then
      raise exception 'Conflict reasons are only for declined assignments';
    end if;
    new.declined_at := null;
    if new.review_state = 'submitted' then
      if new.recommendation is null or btrim(new.comments) = ''
        or not new.conflict_confirmed then
        raise exception 'Recommendation, comment and conflict confirmation are required';
      end if;
      new.submitted_at := now();
    else
      if new.recommendation is not null then
        raise exception 'Recommendations must be submitted';
      end if;
      new.submitted_at := null;
    end if;
  end if;
  return new;
end;
$$;

-- A reviewer cannot review a paper on which their account email is listed as an author.
create function app_private.reject_author_reviewer_assignment() returns trigger
language plpgsql set search_path = '' as $$
begin
  if exists (
    select 1 from public.papers p
    join public.profiles reviewer on reviewer.user_id = new.reviewer_id
    where p.id = new.paper_id
      and (p.owner_id = new.reviewer_id or exists (
        select 1 from public.paper_authors author
        where author.paper_id = p.id and author.email is not null
          and reviewer.email is not null
          and lower(btrim(author.email)) = lower(btrim(reviewer.email))
      ))
  ) then
    raise exception 'Reviewer is an author of this paper';
  end if;
  return new;
end;
$$;
create trigger reject_author_reviewer_assignment
before insert on public.reviews
for each row execute function app_private.reject_author_reviewer_assignment();
revoke all on function app_private.reject_author_reviewer_assignment() from public;

drop policy files_insert on public.paper_files;
create policy files_insert on public.paper_files for insert to authenticated with check (
  uploaded_by = (select auth.uid())
  and split_part(storage_path, '/', 1) = (select auth.uid())::text
  and split_part(storage_path, '/', 2) = paper_id::text
  and exists (
    select 1 from public.papers p
    where p.id = paper_id and p.owner_id = (select auth.uid())
      and (
        (file_stage = 'submission' and p.status in ('draft', 'revision'))
        or (file_stage = 'final' and p.status = 'accepted' and exists (
          select 1 from public.conference_settings
          where final_uploads_open and (final_deadline is null or now() <= final_deadline)
        ))
      )
  )
);

drop policy files_read on public.paper_files;
create policy files_read on public.paper_files for select to authenticated using (
  exists (
    select 1 from public.papers p
    where p.id = paper_id
      and (file_stage = 'submission' or p.owner_id = (select auth.uid())
        or (select app_private.is_chair()))
  )
);

drop policy paper_storage_insert on storage.objects;
create policy paper_storage_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'paper-pdfs'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and exists (
    select 1 from public.papers p
    where p.id::text = (storage.foldername(name))[2]
      and p.owner_id = (select auth.uid())
      and (p.status in ('draft', 'revision') or (p.status = 'accepted' and exists (
        select 1 from public.conference_settings
        where final_uploads_open and (final_deadline is null or now() <= final_deadline)
      )))
  )
);

drop policy paper_storage_read on storage.objects;
create policy paper_storage_read on storage.objects for select to authenticated using (
  bucket_id = 'paper-pdfs' and exists (
    select 1 from public.paper_files f
    join public.papers p on p.id = f.paper_id
    where f.storage_path = name
      and (f.file_stage = 'submission' or p.owner_id = (select auth.uid())
        or (select app_private.is_chair()))
  )
);
