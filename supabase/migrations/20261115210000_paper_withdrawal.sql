-- Author withdrawal of a submitted paper (operator decision 2026-11-15).
-- Status 'withdrawn' with time and optional reason. Allowed for the owner while the paper is
-- submitted, under review, waiting for a revision or accepted; only the chair can change a
-- withdrawn paper afterwards (e.g. restore an accidental withdrawal). Reviews of a withdrawn
-- paper can no longer be submitted (guard_review_update requires 'under_review').
alter table public.papers drop constraint papers_status_check;
alter table public.papers add constraint papers_status_check
  check (status in ('draft', 'submitted', 'under_review', 'revision', 'accepted', 'rejected', 'withdrawn'));
alter table public.papers add column withdrawn_at timestamptz;
alter table public.papers add column withdrawal_reason text not null default ''
  check (char_length(withdrawal_reason) <= 500);

create or replace function app_private.guard_paper_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  -- Author withdrawal (only through public.withdraw_paper): status and withdrawal fields only.
  if new.status = 'withdrawn' and old.status <> 'withdrawn' then
    if not app_private.is_chair() then
      if auth.uid() is distinct from old.owner_id or old.status not in ('submitted','under_review','revision','accepted') then
        raise exception 'Only the author can withdraw a submitted paper';
      end if;
      if (to_jsonb(new) - array['status','withdrawn_at','withdrawal_reason','updated_at'])
         is distinct from (to_jsonb(old) - array['status','withdrawn_at','withdrawal_reason','updated_at']) then
        raise exception 'Withdrawal cannot change other paper fields';
      end if;
    end if;
    new.withdrawn_at := now(); new.withdrawal_reason := btrim(coalesce(new.withdrawal_reason, ''));
    new.updated_at := now();
    return new;
  end if;
  if old.status = 'withdrawn' and not app_private.is_chair() then
    raise exception 'A withdrawn paper can only be changed by the chair';
  end if;
  if not app_private.is_chair() and app_private.is_paper_editor(old.id) then
    if new.status not in ('revision','accepted','rejected') or
      (to_jsonb(new)-array['status','decision_note','final_presentation','assigned_session','decided_by','decided_at','decision_published_at','decision_exception_reason','updated_at'])
      is distinct from
      (to_jsonb(old)-array['status','decision_note','final_presentation','assigned_session','decided_by','decided_at','decision_published_at','decision_exception_reason','updated_at']) then
      raise exception 'Editors may change decision fields only';
    end if;
    new.updated_at:=now(); return new;
  end if;
  if not app_private.is_chair() then
    if new.id <> old.id
      or new.created_at is distinct from old.created_at
      or new.owner_id <> old.owner_id
      or new.edition_year <> old.edition_year
      or new.decision_note <> old.decision_note
      or new.final_presentation is distinct from old.final_presentation
      or new.assigned_session is distinct from old.assigned_session
      or new.decided_at is distinct from old.decided_at
      or (new.status <> 'submitted' and new.submitted_at is distinct from old.submitted_at)
    then
      raise exception 'Only chairs may change identity or decision fields';
    end if;
    if old.status not in ('draft', 'revision')
      or (new.status not in ('draft', 'submitted') and not (old.status = 'revision' and new.status = 'revision'))
    then
      raise exception 'Paper is not editable';
    end if;
  end if;
  if new.status = 'submitted' and old.status <> 'submitted' then
    if not app_private.is_chair() and old.status <> 'revision' and not exists (
      select 1 from public.conference_settings s
      where s.edition_year = new.edition_year
        and s.submissions_open
        and (s.submission_deadline is null or now() <= s.submission_deadline)
    ) then
      raise exception 'Submissions are not open';
    end if;
    if not exists (select 1 from public.paper_authors where paper_id = new.id)
    then
      raise exception 'At least one author is required';
    end if;
    if not exists (select 1 from public.paper_files where paper_id = new.id and file_stage = 'submission')
    then
      raise exception 'A submission PDF is required';
    end if;
    new.submitted_at := now();
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create function public.withdraw_paper(p_paper_id uuid, p_reason text default '') returns void
language plpgsql security definer set search_path = '' as $$
declare p public.papers;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into p from public.papers where id = p_paper_id for update;
  if not found or p.owner_id <> auth.uid() then raise exception 'Only the author can withdraw this paper'; end if;
  if p.status not in ('submitted','under_review','revision','accepted') then
    raise exception 'This paper cannot be withdrawn in its current status';
  end if;
  update public.papers set status = 'withdrawn', withdrawal_reason = left(btrim(coalesce(p_reason, '')), 500)
    where id = p_paper_id;
  update app_private.review_email_outbox set status = 'cancelled', last_error = 'paper_withdrawn'
    where paper_id = p_paper_id and status in ('queued','retry');
end;
$$;
revoke all on function public.withdraw_paper(uuid, text) from public, anon;
grant execute on function public.withdraw_paper(uuid, text) to authenticated;
