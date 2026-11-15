-- Require a full two-person panel for each manuscript version.
-- Applies to RPC decisions and direct updates; existing records are untouched.
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
    if active_count<>2 then
      raise exception 'Exactly two active reviewers are required before publishing'; end if;
    if completed_count<2 and char_length(btrim(new.decision_exception_reason))<5 then
      raise exception 'Incomplete reviews require a public exception reason (at least 5 characters)'; end if;
    if new.status<>'accepted' and (new.final_presentation is not null or new.assigned_session is not null) then
      raise exception 'Presentation and session require an accepted decision'; end if;
    new.decided_by:=auth.uid(); new.decided_at:=now(); new.decision_published_at:=now();
  end if;
  return new;
end; $$;
revoke all on function app_private.guard_chair_decision() from public,anon,authenticated;
