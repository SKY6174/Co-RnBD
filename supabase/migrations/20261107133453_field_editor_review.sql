-- Scoped reviewer/associate-editor roster. No existing papers or stage settings change.
create table public.review_committee (
  id uuid primary key default gen_random_uuid(),
  edition_year integer not null references public.conference_editions(year),
  track text not null check (track in ('master_eng','master_sci','industry_joint','convergence_etc','applied','industry','convergence','education')),
  committee_role text not null check (committee_role in ('reviewer','associate_editor')),
  display_name text not null check (char_length(btrim(display_name)) between 1 and 120),
  email text not null check (email=lower(btrim(email)) and char_length(email)<=254 and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  user_id uuid references public.profiles(user_id) on delete set null,
  active boolean not null default true,
  unique(edition_year,track,email,committee_role)
);
create index review_committee_user_idx on public.review_committee(user_id);
alter table public.review_committee enable row level security;
revoke all on public.review_committee from public,anon,authenticated;
grant select,insert,update on public.review_committee to authenticated;

create function app_private.is_associate_editor(p_year integer,p_track text) returns boolean
language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and p_year=app_private.current_edition_year() and exists (
    select 1 from public.review_committee c join auth.users u on lower(u.email)=c.email
    where u.id=auth.uid() and u.email_confirmed_at is not null and c.edition_year=p_year
      and c.track=p_track and c.committee_role='associate_editor' and c.active);
$$;
revoke all on function app_private.is_associate_editor(integer,text) from public,anon;
grant execute on function app_private.is_associate_editor(integer,text) to authenticated;

create function app_private.is_paper_editor(p_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and exists (
    select 1 from public.papers p where p.id=p_id and p.status<>'draft' and p.submitted_at is not null
    and app_private.is_associate_editor(p.edition_year,p.track) and p.owner_id<>auth.uid()
    and not exists(select 1 from public.paper_authors a join auth.users u on u.id=auth.uid()
      where a.paper_id=p.id and lower(btrim(a.email))=lower(u.email)));
$$;
revoke all on function app_private.is_paper_editor(uuid) from public,anon;
grant execute on function app_private.is_paper_editor(uuid) to authenticated;

create function app_private.can_decide_paper(p_id uuid) returns boolean
language sql stable security invoker set search_path='' as $$
  select auth.uid() is not null and (app_private.is_chair() or app_private.is_paper_editor(p_id));
$$;
revoke all on function app_private.can_decide_paper(uuid) from public,anon;
grant execute on function app_private.can_decide_paper(uuid) to authenticated;

create policy committee_read on public.review_committee for select to authenticated using (
  (select app_private.is_chair()) or user_id=(select auth.uid()) or app_private.is_associate_editor(edition_year,track));
create policy committee_insert on public.review_committee for insert to authenticated with check ((select app_private.is_chair()));
create policy committee_update on public.review_committee for update to authenticated using ((select app_private.is_chair())) with check ((select app_private.is_chair()));

create function app_private.bind_committee_account() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  new.email:=lower(btrim(new.email)); new.display_name:=btrim(new.display_name);
  select p.user_id into new.user_id from public.profiles p join auth.users u on u.id=p.user_id
    where lower(u.email)=new.email and u.email_confirmed_at is not null;
  return new;
end; $$;
revoke all on function app_private.bind_committee_account() from public,anon,authenticated;
create trigger bind_committee_account before insert or update on public.review_committee
  for each row execute function app_private.bind_committee_account();

create policy papers_editor_read on public.papers for select to authenticated using (app_private.is_paper_editor(id));
create policy reviews_editor_read on public.reviews for select to authenticated using (app_private.is_paper_editor(paper_id));
-- Draft comments in audit records remain chair-only; editors use submitted reviews.

create or replace function app_private.guard_paper_update() returns trigger
language plpgsql set search_path = '' as $$
begin
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

create or replace function app_private.guard_chair_decision() returns trigger
language plpgsql set search_path='' as $$
declare active_count integer; completed_count integer; changed boolean;
begin
  if tg_op='INSERT' then
    if new.decided_by is not null or new.decision_published_at is not null or new.decision_exception_reason<>'' then
      raise exception 'Decision metadata cannot be set on creation'; end if;
    return new;
  end if;
  if not app_private.can_decide_paper(old.id) then
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
    if completed_count<2 and not app_private.is_chair() then raise exception 'Editors require two completed reviews'; end if;
    if completed_count<2 and char_length(btrim(new.decision_exception_reason))<5 then
      raise exception 'Incomplete reviews require a public exception reason (at least 5 characters)'; end if;
    if new.status<>'accepted' and (new.final_presentation is not null or new.assigned_session is not null) then
      raise exception 'Presentation and session require an accepted decision'; end if;
    new.decided_by:=auth.uid(); new.decided_at:=now(); new.decision_published_at:=now();
  end if;
  return new;
end; $$;
revoke all on function app_private.guard_chair_decision() from public,anon,authenticated;

create function app_private.publish_editor_decision(p_paper_id uuid,p_status text,p_note text,p_presentation text,p_session text,p_exception_reason text,p_expected_updated_at timestamptz,p_expected_reviews jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare p public.papers; current_reviews jsonb;
begin
  if auth.uid() is null or not app_private.can_decide_paper(p_paper_id) then raise exception 'Chair permission required'; end if;
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
revoke all on function app_private.publish_editor_decision(uuid,text,text,text,text,text,timestamptz,jsonb) from public,anon;
grant execute on function app_private.publish_editor_decision(uuid,text,text,text,text,text,timestamptz,jsonb) to authenticated;
create or replace function public.chair_publish_decision(p_paper_id uuid,p_status text,p_note text,p_presentation text,p_session text,p_exception_reason text,p_expected_updated_at timestamptz,p_expected_reviews jsonb) returns void
language sql security invoker set search_path='' as $$
  select app_private.publish_editor_decision(p_paper_id,p_status,p_note,p_presentation,p_session,p_exception_reason,p_expected_updated_at,p_expected_reviews);
$$;
revoke all on function public.chair_publish_decision(uuid,text,text,text,text,text,timestamptz,jsonb) from public,anon;
grant execute on function public.chair_publish_decision(uuid,text,text,text,text,text,timestamptz,jsonb) to authenticated;

create function app_private.author_review_feedback(p_id uuid) returns table(recommendation text,comments text)
language sql stable security definer set search_path='' as $$
  select r.recommendation,r.comments from public.reviews r join public.papers p on p.id=r.paper_id
  where auth.uid() is not null and p.id=p_id and p.owner_id=auth.uid()
    and p.status in ('revision','accepted','rejected') and p.decision_published_at is not null
    and r.manuscript_submitted_at=p.submitted_at and r.revoked_at is null
    and r.review_state='submitted' and r.submitted_at<=p.decision_published_at order by r.id;
$$;
revoke all on function app_private.author_review_feedback(uuid) from public,anon;
grant execute on function app_private.author_review_feedback(uuid) to authenticated;
create function public.author_review_feedback(p_id uuid) returns table(recommendation text,comments text)
language sql stable security invoker set search_path='' as $$
  select * from app_private.author_review_feedback(p_id);
$$;
revoke all on function public.author_review_feedback(uuid) from public,anon;
grant execute on function public.author_review_feedback(uuid) to authenticated;

-- Once a field roster exists, new requests must use an active field reviewer.
create function app_private.check_field_reviewer() returns trigger
language plpgsql security definer set search_path='' as $$
declare y integer; t text;
begin
  select edition_year,track into y,t from public.papers where id=new.paper_id;
  if exists(select 1 from public.review_committee where edition_year=y and track=t and committee_role='reviewer')
    and not exists(select 1 from public.review_committee c join auth.users u on lower(u.email)=c.email
      where c.edition_year=y and c.track=t and c.committee_role='reviewer' and c.active
        and u.id=new.reviewer_id and u.email_confirmed_at is not null) then
    raise exception 'Active field reviewer membership required';
  end if;
  return new;
end; $$;
revoke all on function app_private.check_field_reviewer() from public,anon,authenticated;
create trigger committee_reviewer_guard before insert on public.reviews for each row execute function app_private.check_field_reviewer();
