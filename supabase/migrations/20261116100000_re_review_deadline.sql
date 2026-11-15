-- Separate deadline for re-reviewing a resubmitted (revised) manuscript (schedule approved 2026-11-15:
-- first-round reviews close 2026-12-30 18:00 KST, re-reviews of revisions close 2027-01-11 18:00 KST).
-- Removes the manual step of moving review_deadline after the 01-04 decisions. When
-- re_review_deadline is null, re-reviews use review_deadline as before.
alter table public.conference_settings add column re_review_deadline timestamptz;

-- A manuscript version is a revision when it was submitted from the 'revision' status.
create function app_private.is_revised_submission(p_paper uuid, p_submitted_at timestamptz) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.paper_events e
    where e.paper_id = p_paper and e.action = 'paper_submitted'
      and e.before_data ->> 'status' = 'revision'
      and (e.after_data ->> 'submitted_at')::timestamptz = p_submitted_at);
$$;
revoke all on function app_private.is_revised_submission(uuid, timestamptz) from public, anon, authenticated;

create function app_private.review_window_open(p_paper uuid, p_submitted_at timestamptz) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.conference_settings s join public.papers p on p.edition_year = s.edition_year
    where p.id = p_paper and s.reviews_open
      and (case when s.re_review_deadline is not null and app_private.is_revised_submission(p_paper, p_submitted_at)
             then now() <= s.re_review_deadline
             else s.review_deadline is null or now() <= s.review_deadline end));
$$;
revoke all on function app_private.review_window_open(uuid, timestamptz) from public, anon, authenticated;
-- Called by the review update guard, which runs as the reviewer; returns only a boolean.
grant execute on function app_private.review_window_open(uuid, timestamptz) to authenticated;

-- For the reviewer screen: which of my current assignments are re-reviews of a revision.
create function public.my_re_review_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select r.id from public.reviews r join public.papers p on p.id = r.paper_id
  where r.reviewer_id = auth.uid() and r.manuscript_submitted_at = p.submitted_at
    and app_private.is_revised_submission(p.id, r.manuscript_submitted_at);
$$;
revoke all on function public.my_re_review_ids() from public, anon;
grant execute on function public.my_re_review_ids() to authenticated;

-- Unchanged from 20261014222650 except the deadline check.
create or replace function app_private.guard_review_update() returns trigger
language plpgsql set search_path='' as $$
declare p public.papers;
begin
  if new.id<>old.id or new.paper_id<>old.paper_id or new.reviewer_id<>old.reviewer_id or new.assigned_at is distinct from old.assigned_at
    or new.manuscript_submitted_at is distinct from old.manuscript_submitted_at then raise exception 'Review assignment cannot be changed'; end if;
  select * into p from public.papers where id=new.paper_id;
  if old.revoked_at is not null then raise exception 'Revoked assignments are read only'; end if;
  if p.submitted_at is distinct from old.manuscript_submitted_at then raise exception 'Previous manuscript reviews are read only'; end if;
  if new.revoked_at is distinct from old.revoked_at or new.revoked_by is distinct from old.revoked_by or new.revocation_reason is distinct from old.revocation_reason then
    if not app_private.is_chair() or new.revoked_at is null or p.status not in ('submitted','under_review')
      or (to_jsonb(new)-array['revoked_at','revoked_by','revocation_reason']) is distinct from (to_jsonb(old)-array['revoked_at','revoked_by','revocation_reason'])
      then raise exception 'Only chairs can revoke an assignment without editing its review'; end if;
    new.revoked_by:=auth.uid(); new.revoked_at:=now(); return new;
  end if;
  if auth.uid() is distinct from old.reviewer_id or p.status<>'under_review' then raise exception 'Only the assigned reviewer can submit a review'; end if;
  if old.review_state='declined' then raise exception 'Declined review assignments cannot be edited'; end if;
  if old.review_state='submitted' and new.review_state in ('assigned','draft') then raise exception 'Submitted reviews cannot return to draft'; end if;
  if new.review_state='declined' then
    if btrim(new.decline_reason)='' then raise exception 'A conflict reason is required'; end if;
    new.recommendation:=null; new.comments:=''; new.conflict_confirmed:=false; new.submitted_at:=null; new.declined_at:=now();
  else
    if not app_private.review_window_open(p.id,old.manuscript_submitted_at) then raise exception 'Review submission is closed'; end if;
    if new.decline_reason<>'' then raise exception 'Conflict reasons are only for declined assignments'; end if;
    new.declined_at:=null;
    if new.review_state='submitted' then
      if new.recommendation is null or btrim(new.comments)='' or not new.conflict_confirmed then raise exception 'Recommendation, comment and conflict confirmation are required'; end if;
      new.submitted_at:=now();
    else
      if new.recommendation is not null then raise exception 'Recommendations must be submitted'; end if;
      new.submitted_at:=null;
    end if;
  end if;
  return new;
end; $$;

update public.conference_settings set re_review_deadline = '2027-01-11 18:00:00+09'
  where edition_year = 2026 and re_review_deadline is null;
