drop policy papers_insert on public.papers;
create policy papers_insert on public.papers for insert to authenticated with check (
  owner_id = (select auth.uid())
  and status = 'draft'
  and decision_note = ''
  and final_presentation is null
  and submitted_at is null
  and decided_at is null
  and exists (select 1 from public.conference_settings where submissions_open)
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
    if not app_private.is_chair() and not exists
      (select 1 from public.conference_settings where submissions_open) then
      raise exception 'Submissions are not open';
    end if;
    if not exists (select 1 from public.paper_files where paper_id = new.id) then
      raise exception 'A PDF is required before submission';
    end if;
    new.submitted_at := now();
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop policy reviews_assign on public.reviews;
create policy reviews_assign on public.reviews for insert to authenticated with check (
  app_private.is_chair()
  and recommendation is null
  and comments = ''
  and conflict_confirmed = false
  and submitted_at is null
  and exists (select 1 from public.papers p
    where p.id = paper_id and p.owner_id <> reviewer_id
      and p.status in ('submitted', 'under_review'))
);

create or replace function app_private.guard_review_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.id <> old.id or new.paper_id <> old.paper_id
    or new.reviewer_id <> old.reviewer_id
    or new.assigned_at is distinct from old.assigned_at then
    raise exception 'Review assignment cannot be changed';
  end if;
  if new.recommendation is not null
    and (btrim(new.comments) = '' or not new.conflict_confirmed) then
    raise exception 'Comment and conflict confirmation are required';
  end if;
  new.submitted_at := case when new.recommendation is null then null else now() end;
  return new;
end;
$$;
