alter table public.reviews
  add column review_state text not null default 'assigned'
    check (review_state in ('assigned', 'draft', 'submitted', 'declined')),
  add column decline_reason text not null default '',
  add column declined_at timestamptz;

update public.reviews
set review_state = case
  when recommendation is not null then 'submitted'
  when btrim(comments) <> '' or conflict_confirmed then 'draft'
  else 'assigned'
end;

alter table public.reviews add constraint reviews_state_consistency check (
  (review_state = 'assigned' and recommendation is null and comments = ''
    and not conflict_confirmed and submitted_at is null
    and declined_at is null and decline_reason = '')
  or (review_state = 'draft' and recommendation is null and submitted_at is null
    and declined_at is null and decline_reason = '')
  or (review_state = 'submitted' and recommendation is not null
    and btrim(comments) <> '' and conflict_confirmed and submitted_at is not null
    and declined_at is null and decline_reason = '')
  or (review_state = 'declined' and recommendation is null and submitted_at is null
    and declined_at is not null and btrim(decline_reason) <> '')
);

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

drop policy papers_read on public.papers;
create policy papers_read on public.papers for select to authenticated using (
  owner_id = (select auth.uid()) or app_private.is_chair() or
  exists (select 1 from public.reviews r where r.paper_id = id
    and r.reviewer_id = (select auth.uid()) and r.review_state <> 'declined')
);

drop policy reviews_assign on public.reviews;
create policy reviews_assign on public.reviews for insert to authenticated with check (
  app_private.is_chair() and review_state = 'assigned'
  and recommendation is null and comments = '' and not conflict_confirmed
  and submitted_at is null and declined_at is null and decline_reason = ''
  and exists (select 1 from public.papers p
    where p.id = paper_id and p.owner_id <> reviewer_id
      and p.status in ('submitted', 'under_review'))
);

drop policy reviews_reviewer_update on public.reviews;
create policy reviews_reviewer_update on public.reviews for update to authenticated
  using (reviewer_id = (select auth.uid()) and review_state <> 'declined'
    and exists (select 1 from public.papers p
      where p.id = paper_id and p.status = 'under_review'))
  with check (reviewer_id = (select auth.uid()));
