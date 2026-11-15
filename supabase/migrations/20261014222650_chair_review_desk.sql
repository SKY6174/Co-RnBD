-- Chair desk: preserve assignments and decisions, authorize every write in Postgres.
alter table public.papers
  add column decided_by uuid references public.profiles(user_id),
  add column decision_published_at timestamptz,
  add column decision_exception_reason text not null default '' check (char_length(decision_exception_reason) <= 1000);
alter table public.reviews
  add column manuscript_submitted_at timestamptz,
  add column revoked_at timestamptz,
  add column revoked_by uuid references public.profiles(user_id),
  add column revocation_reason text not null default '';
update public.reviews r set manuscript_submitted_at = coalesce(p.submitted_at,r.assigned_at)
  from public.papers p where p.id=r.paper_id;
alter table public.reviews alter column manuscript_submitted_at set not null;
alter table public.reviews drop constraint reviews_paper_id_reviewer_id_key;
alter table public.reviews add constraint reviews_manuscript_reviewer_key unique(paper_id,reviewer_id,manuscript_submitted_at);
alter table public.reviews add constraint reviews_revocation_consistency check (
  (revoked_at is null and revoked_by is null and revocation_reason='') or
  (revoked_at is not null and revoked_by is not null and char_length(btrim(revocation_reason)) between 5 and 1000));
create index reviews_revoked_by_idx on public.reviews(revoked_by);
create index papers_decided_by_idx on public.papers(decided_by);

create table public.paper_events (
  id uuid primary key default gen_random_uuid(),
  paper_id uuid not null references public.papers(id) on delete cascade,
  actor_id uuid references public.profiles(user_id) on delete set null,
  actor_label text not null,
  action text not null,
  before_data jsonb,
  after_data jsonb not null,
  created_at timestamptz not null default now()
);
create index paper_events_paper_time_idx on public.paper_events(paper_id,created_at desc);
create index paper_events_actor_idx on public.paper_events(actor_id);
alter table public.paper_events enable row level security;
revoke all on public.paper_events from public,anon,authenticated;
grant select on public.paper_events to authenticated;
create policy paper_events_chair_read on public.paper_events for select to authenticated using ((select app_private.is_chair()));

create table public.paper_final_checks (
  paper_id uuid primary key references public.papers(id) on delete cascade,
  file_id uuid not null unique references public.paper_files(id),
  checked_by uuid not null references public.profiles(user_id),
  checked_at timestamptz not null default now()
);
create index paper_final_checks_by_idx on public.paper_final_checks(checked_by);
alter table public.paper_final_checks enable row level security;
revoke all on public.paper_final_checks from public,anon,authenticated;
grant select,insert,update on public.paper_final_checks to authenticated;
create policy final_checks_read on public.paper_final_checks for select to authenticated using (
  (select app_private.is_chair()) or exists(select 1 from public.papers p where p.id=paper_id and p.owner_id=(select auth.uid())));
create policy final_checks_insert on public.paper_final_checks for insert to authenticated with check ((select app_private.is_chair()));
create policy final_checks_update on public.paper_final_checks for update to authenticated using ((select app_private.is_chair())) with check ((select app_private.is_chair()));

-- Internal audit trigger is the only writer. Not an exposed RPC.
create function app_private.record_paper_event() returns trigger
language plpgsql security definer set search_path='' as $$
declare action_name text; target uuid; previous jsonb; current_data jsonb; actor_name text;
begin
  if tg_table_name='papers' then
    target:=new.id;
    if new.decision_published_at is distinct from old.decision_published_at then action_name:='decision_published';
    elsif new.status='submitted' and old.status<>'submitted' then action_name:='paper_submitted';
    elsif new.status is distinct from old.status then action_name:='paper_status_changed';
    else return new; end if;
    previous:=jsonb_build_object('status',old.status,'note',old.decision_note,'presentation',old.final_presentation,'session',old.assigned_session);
    current_data:=jsonb_build_object('status',new.status,'note',new.decision_note,'presentation',new.final_presentation,'session',new.assigned_session,'exception_reason',new.decision_exception_reason,'submitted_at',new.submitted_at);
  elsif tg_table_name='reviews' then
    target:=new.paper_id;
    if tg_op='INSERT' then action_name:='review_assigned';
    elsif new.revoked_at is distinct from old.revoked_at then action_name:='review_revoked';
    elsif new.review_state='submitted' then action_name:='review_submitted';
    elsif new.review_state='declined' and old.review_state<>'declined' then action_name:='review_declined';
    else return new; end if;
    if tg_op='UPDATE' then previous:=to_jsonb(old); end if;
    current_data:=to_jsonb(new);
  elsif tg_table_name='paper_files' then
    target:=new.paper_id; action_name:='file_uploaded';
    current_data:=jsonb_build_object('file_id',new.id,'version',new.version,'stage',new.file_stage,'name',new.original_name);
  else
    target:=new.paper_id; action_name:='final_checked';
    if tg_op='UPDATE' then previous:=to_jsonb(old); end if;
    current_data:=to_jsonb(new);
  end if;
  select coalesce(nullif(full_name,''),'회원') into actor_name from public.profiles where user_id=auth.uid();
  insert into public.paper_events(paper_id,actor_id,actor_label,action,before_data,after_data)
    values(target,auth.uid(),coalesce(actor_name,'시스템'),action_name,previous,current_data);
  return new;
end; $$;
revoke all on function app_private.record_paper_event() from public,anon,authenticated;
create trigger paper_events_papers after update on public.papers for each row execute function app_private.record_paper_event();
create trigger paper_events_reviews after insert or update on public.reviews for each row execute function app_private.record_paper_event();
create trigger paper_events_files after insert on public.paper_files for each row execute function app_private.record_paper_event();
create trigger paper_events_checks after insert or update on public.paper_final_checks for each row execute function app_private.record_paper_event();

create function app_private.guard_chair_decision() returns trigger
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
create trigger chair_decision_guard before insert or update on public.papers for each row execute function app_private.guard_chair_decision();

create function app_private.guard_review_assignment() returns trigger
language plpgsql set search_path='' as $$
declare p public.papers; active_count integer;
begin
  select * into p from public.papers where id=new.paper_id for update;
  if not app_private.is_chair() or p.id is null or p.edition_year<>app_private.current_edition_year()
    or p.status not in ('submitted','under_review') or p.submitted_at is null then raise exception 'Only chairs can assign submitted current papers'; end if;
  if new.revoked_at is not null or new.revoked_by is not null or new.revocation_reason<>'' then raise exception 'New assignments cannot be revoked'; end if;
  new.manuscript_submitted_at:=p.submitted_at;
  select count(*) into active_count from public.reviews where paper_id=p.id and manuscript_submitted_at=p.submitted_at and revoked_at is null and review_state<>'declined';
  if active_count>=2 then raise exception 'At most two active reviewers may be assigned'; end if;
  return new;
end; $$;
revoke all on function app_private.guard_review_assignment() from public,anon,authenticated;
create trigger guard_review_assignment before insert on public.reviews for each row execute function app_private.guard_review_assignment();

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
    if not exists(select 1 from public.conference_settings s where s.edition_year=p.edition_year and s.reviews_open and (s.review_deadline is null or now()<=s.review_deadline)) then raise exception 'Review submission is closed'; end if;
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
create policy reviews_chair_revoke on public.reviews for update to authenticated using ((select app_private.is_chair())) with check ((select app_private.is_chair()) and revoked_at is not null);
create or replace function app_private.has_active_review(p_paper_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.reviews r join public.papers p on p.id=r.paper_id
    where r.paper_id=p_paper_id and r.reviewer_id=(select auth.uid()) and r.review_state<>'declined'
    and r.revoked_at is null and r.manuscript_submitted_at=p.submitted_at);
$$;

create function public.chair_assign_reviewer(p_paper_id uuid,p_reviewer_id uuid,p_replace_review_id uuid default null,p_reason text default '') returns uuid
language plpgsql security invoker set search_path='' as $$
declare p public.papers; saved uuid;
begin
  if auth.uid() is null or not app_private.is_chair() then raise exception 'Chair permission required'; end if;
  select * into p from public.papers where id=p_paper_id for update;
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

create function public.chair_publish_decision(p_paper_id uuid,p_status text,p_note text,p_presentation text,p_session text,p_exception_reason text,p_expected_updated_at timestamptz) returns void
language plpgsql security invoker set search_path='' as $$
declare p public.papers;
begin
  if auth.uid() is null or not app_private.is_chair() then raise exception 'Chair permission required'; end if;
  select * into p from public.papers where id=p_paper_id for update;
  if p.id is null or p.edition_year<>app_private.current_edition_year() or p.updated_at is distinct from p_expected_updated_at then raise exception 'Paper changed; refresh before publishing'; end if;
  if p_status is null or p_status not in ('revision','accepted','rejected') then raise exception 'Choose a valid decision'; end if;
  update public.papers set status=p_status,decision_note=btrim(coalesce(p_note,'')),final_presentation=nullif(p_presentation,''),assigned_session=nullif(p_session,''),
    decision_exception_reason=btrim(coalesce(p_exception_reason,'')),decision_published_at=now() where id=p.id;
end; $$;
revoke all on function public.chair_publish_decision(uuid,text,text,text,text,text,timestamptz) from public,anon;
grant execute on function public.chair_publish_decision(uuid,text,text,text,text,text,timestamptz) to authenticated;

-- Serialize upload metadata and final confirmation on the same paper. This internal
-- definer trigger only locks an owner-authorized parent; it does not grant UPDATE rights.
create function app_private.lock_file_parent() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  perform 1 from public.papers where id=new.paper_id and owner_id=auth.uid() for update;
  if not found then raise exception 'Only the owner can upload this paper'; end if;
  return new;
end; $$;
revoke all on function app_private.lock_file_parent() from public,anon,authenticated;
create trigger lock_file_parent before insert on public.paper_files for each row execute function app_private.lock_file_parent();
create function app_private.guard_final_check() returns trigger
language plpgsql set search_path='' as $$
declare p public.papers; latest uuid;
begin
  if auth.uid() is null or not app_private.is_chair() then raise exception 'Chair permission required'; end if;
  if tg_op='UPDATE' and new.paper_id<>old.paper_id then raise exception 'Paper cannot be changed'; end if;
  select * into p from public.papers where id=new.paper_id for update;
  if p.id is null or p.status<>'accepted' or p.edition_year<>app_private.current_edition_year() then raise exception 'Only current accepted papers can be checked'; end if;
  select id into latest from public.paper_files where paper_id=p.id and file_stage='final' order by version desc limit 1;
  if latest is null or new.file_id is distinct from latest then raise exception 'Only the latest final PDF can be confirmed'; end if;
  new.checked_by:=auth.uid(); new.checked_at:=now(); return new;
end; $$;
revoke all on function app_private.guard_final_check() from public,anon,authenticated;
create trigger final_check_guard before insert or update on public.paper_final_checks for each row execute function app_private.guard_final_check();
