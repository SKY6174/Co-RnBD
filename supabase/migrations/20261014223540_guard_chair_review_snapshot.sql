-- Recheck the exact review content shown to the chair before publishing.
-- NO KEY UPDATE still serializes paper changes while allowing audit FK checks.
create or replace function public.chair_assign_reviewer(p_paper_id uuid,p_reviewer_id uuid,p_replace_review_id uuid default null,p_reason text default '') returns uuid
language plpgsql security invoker set search_path='' as $$
declare p public.papers; saved uuid;
begin
  if auth.uid() is null or not app_private.is_chair() then raise exception 'Chair permission required'; end if;
  select * into p from public.papers where id=p_paper_id for no key update;
  if p.id is null or p.edition_year<>app_private.current_edition_year() or p.status not in ('submitted','under_review') then raise exception 'Paper is not assignable'; end if;
  if p_replace_review_id is not null then
    update public.reviews set revoked_at=now(),revoked_by=auth.uid(),revocation_reason=btrim(p_reason)
      where id=p_replace_review_id and paper_id=p.id and manuscript_submitted_at=p.submitted_at and revoked_at is null;
    if not found then raise exception 'Assignment changed; refresh the paper'; end if;
  end if;
  insert into public.reviews(paper_id,reviewer_id) values(p.id,p_reviewer_id) returning id into saved;
  update public.papers set status='under_review' where id=p.id;
  return saved;
end; $$;
revoke all on function public.chair_assign_reviewer(uuid,uuid,uuid,text) from public,anon;
grant execute on function public.chair_assign_reviewer(uuid,uuid,uuid,text) to authenticated;


create or replace function app_private.guard_chair_decision() returns trigger
language plpgsql set search_path='' as $$
declare active_count integer; completed_count integer; changed boolean;
begin
  if tg_op='INSERT' then
    if new.decided_by is not null or new.decision_published_at is not null or new.decision_exception_reason<>'' then
      raise exception 'Decision metadata cannot be set on creation'; end if;
    return new;
  end if;
  if not app_private.is_chair() then
    if new.decided_by is distinct from old.decided_by or new.decision_published_at is distinct from old.decision_published_at
      or new.decision_exception_reason is distinct from old.decision_exception_reason then
      raise exception 'Only chairs can publish decisions'; end if;
    return new;
  end if;
  changed := new.decision_note is distinct from old.decision_note or new.final_presentation is distinct from old.final_presentation
    or new.assigned_session is distinct from old.assigned_session or new.decided_by is distinct from old.decided_by
    or new.decision_published_at is distinct from old.decision_published_at or new.decided_at is distinct from old.decided_at
    or new.decision_exception_reason is distinct from old.decision_exception_reason
    or (new.status is distinct from old.status and new.status in ('revision','accepted','rejected'));
  if changed then
    if auth.uid() is null or old.status='draft' or new.status not in ('revision','accepted','rejected') then
      raise exception 'A submitted paper and a valid decision are required'; end if;
    if char_length(btrim(new.decision_note)) not between 1 and 5000 then raise exception 'A public decision note is required (1-5000 characters)'; end if;
    -- Wait for in-flight review edits before checking completion.
    perform 1 from public.reviews where paper_id=new.id
      and manuscript_submitted_at=old.submitted_at order by id for update;
    select count(*),count(*) filter(where review_state='submitted') into active_count,completed_count
      from public.reviews where paper_id=new.id and manuscript_submitted_at=old.submitted_at and revoked_at is null and review_state<>'declined';
    if (active_count=0 or completed_count<active_count) and char_length(btrim(new.decision_exception_reason))<5 then
      raise exception 'Incomplete reviews require a public exception reason (at least 5 characters)'; end if;
    if new.status<>'accepted' and (new.final_presentation is not null or new.assigned_session is not null) then
      raise exception 'Presentation and session require an accepted decision'; end if;
    new.decided_by:=auth.uid(); new.decided_at:=now(); new.decision_published_at:=now();
  end if;
  return new;
end; $$;
revoke all on function app_private.guard_chair_decision() from public,anon,authenticated;

-- Old cached clients must reload rather than bypass the review comparison.
create or replace function public.chair_publish_decision(p_paper_id uuid,p_status text,p_note text,p_presentation text,p_session text,p_exception_reason text,p_expected_updated_at timestamptz) returns void
language plpgsql security invoker set search_path='' as $$
begin
  if auth.uid() is null or not app_private.is_chair() then raise exception 'Chair permission required'; end if;
  raise exception 'Review snapshot required; refresh before publishing';
end; $$;

create function public.chair_publish_decision(p_paper_id uuid,p_status text,p_note text,p_presentation text,p_session text,p_exception_reason text,p_expected_updated_at timestamptz,p_expected_reviews jsonb) returns void
language plpgsql security invoker set search_path='' as $$
declare p public.papers; current_reviews jsonb;
begin
  if auth.uid() is null or not app_private.is_chair() then raise exception 'Chair permission required'; end if;
  select * into p from public.papers where id=p_paper_id for no key update;
  if p.id is null or p.edition_year<>app_private.current_edition_year() or p.updated_at is distinct from p_expected_updated_at then raise exception 'Paper changed; refresh before publishing'; end if;
  if p_expected_reviews is null or jsonb_typeof(p_expected_reviews)<>'array' then
    raise exception 'Review snapshot required; refresh before publishing'; end if;
  -- Same order in every decision; the parent lock blocks concurrent assignments.
  perform 1 from public.reviews where paper_id=p.id
    and manuscript_submitted_at=p.submitted_at order by id for update;
  select coalesce(jsonb_agg(to_jsonb(r) order by r.id),'[]'::jsonb) into current_reviews
    from public.reviews r where r.paper_id=p.id and r.manuscript_submitted_at=p.submitted_at;
  if current_reviews is distinct from p_expected_reviews then
    raise exception 'Reviews changed; refresh before publishing'; end if;
  if p_status is null or p_status not in ('revision','accepted','rejected') then raise exception 'Choose a valid decision'; end if;
  update public.papers set status=p_status,decision_note=btrim(coalesce(p_note,'')),final_presentation=nullif(p_presentation,''),assigned_session=nullif(p_session,''),
    decision_exception_reason=btrim(coalesce(p_exception_reason,'')),decision_published_at=now() where id=p.id;
end; $$;
revoke all on function public.chair_publish_decision(uuid,text,text,text,text,text,timestamptz,jsonb) from public,anon;
grant execute on function public.chair_publish_decision(uuid,text,text,text,text,text,timestamptz,jsonb) to authenticated;
