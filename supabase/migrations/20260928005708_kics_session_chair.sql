-- Session chairs receive authority for their assigned session only.
create table public.session_chairs (
  session_id uuid primary key references public.program_sessions(id) on delete cascade,
  user_id uuid not null references public.profiles(user_id),
  assigned_at timestamptz not null default now(),
  report_note text not null default '' check (char_length(report_note) <= 1000),
  report_submitted_at timestamptz
);
create index session_chairs_user_idx on public.session_chairs(user_id);

create table public.session_presentations (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.program_sessions(id) on delete cascade,
  paper_id uuid not null unique references public.papers(id),
  paper_title text not null,
  presenter_name text not null check (char_length(btrim(presenter_name)) between 1 and 120),
  attendance text not null default 'pending' check (attendance in ('pending', 'presented', 'absent')),
  award_recommended boolean not null default false,
  chair_note text not null default '' check (char_length(chair_note) <= 500),
  recorded_at timestamptz,
  created_at timestamptz not null default now()
);
create index session_presentations_session_idx on public.session_presentations(session_id, created_at);

create function app_private.is_session_chair(p_session_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.session_chairs sc
    join public.program_sessions s on s.id = sc.session_id
    join public.conference_editions e on e.year = s.edition_year
    where sc.session_id = p_session_id and sc.user_id = (select auth.uid())
      and e.status = 'current'
  );
$$;
revoke all on function app_private.is_session_chair(uuid) from public;
grant execute on function app_private.is_session_chair(uuid) to authenticated;

create function app_private.session_chair_has_author_conflict(p_session_id uuid, p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.session_presentations sp
    join public.papers p on p.id = sp.paper_id
    left join public.profiles profile on profile.user_id = p_user_id
    where sp.session_id = p_session_id
      and (p.owner_id = p_user_id or exists (
        select 1 from public.paper_authors author
        where author.paper_id = p.id and profile.email is not null
          and lower(btrim(author.email)) = lower(btrim(profile.email))
      ))
  );
$$;
revoke all on function app_private.session_chair_has_author_conflict(uuid, uuid) from public;

create function app_private.guard_session_chair() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_type text; v_status text;
begin
  select s.session_type, e.status into v_type, v_status
    from public.program_sessions s join public.conference_editions e on e.year = s.edition_year
    where s.id = new.session_id;
  if v_type not in ('oral', 'poster') or v_status <> 'current' then
    raise exception 'Only current oral and poster sessions can have a chair';
  end if;
  if tg_op = 'INSERT' then
    if not app_private.is_chair() then raise exception 'Only the conference chair assigns session chairs'; end if;
    new.assigned_at := now();
    new.report_note := '';
    new.report_submitted_at := null;
  elsif not app_private.is_chair() then
    if new.session_id <> old.session_id or new.user_id <> old.user_id
      or new.assigned_at is distinct from old.assigned_at
      or old.report_submitted_at is not null
      or new.report_submitted_at is null then
      raise exception 'Session chairs may only submit their own report once';
    end if;
    if not exists (select 1 from public.session_presentations where session_id = new.session_id) or exists (
      select 1 from public.session_presentations
      where session_id = new.session_id and attendance = 'pending'
    ) then raise exception 'Record every presentation before submitting the report'; end if;
    new.report_submitted_at := now();
  else
    if new.session_id <> old.session_id or new.assigned_at is distinct from old.assigned_at then
      raise exception 'Session assignment identity cannot be changed';
    end if;
    if new.user_id <> old.user_id then
      if old.report_submitted_at is not null then
        raise exception 'Reopen the submitted report before replacing the session chair';
      end if;
      new.assigned_at := now();
      new.report_note := '';
      new.report_submitted_at := null;
    elsif old.report_submitted_at is not null and new.report_submitted_at is null then
      -- The conference chair may reopen a submitted report for correction.
      null;
    elsif new.report_submitted_at is distinct from old.report_submitted_at
      or new.report_note is distinct from old.report_note then
      raise exception 'The conference chair may only reopen a submitted report';
    end if;
  end if;
  if app_private.session_chair_has_author_conflict(new.session_id, new.user_id) then
    raise exception 'A paper author cannot chair their own session';
  end if;
  return new;
end;
$$;
create trigger guard_session_chair before insert or update on public.session_chairs
  for each row execute function app_private.guard_session_chair();

create function app_private.guard_session_chair_delete() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.report_submitted_at is not null then
    raise exception 'Reopen the submitted report before removing the session chair';
  end if;
  return old;
end;
$$;
create trigger guard_session_chair_delete before delete on public.session_chairs
  for each row execute function app_private.guard_session_chair_delete();

create function app_private.guard_session_presentation() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_paper public.papers%rowtype; v_type text; v_year integer; v_status text;
begin
  if tg_op = 'UPDATE' then
    if new.id <> old.id or new.session_id <> old.session_id or new.paper_id <> old.paper_id
      or new.paper_title is distinct from old.paper_title
      or new.created_at is distinct from old.created_at then
      raise exception 'Presentation identity cannot be changed';
    end if;
  end if;
  select s.session_type, s.edition_year, e.status into v_type, v_year, v_status
    from public.program_sessions s join public.conference_editions e on e.year = s.edition_year
    where s.id = new.session_id;
  if v_type not in ('oral', 'poster') or v_status <> 'current' then
    raise exception 'Only current oral and poster sessions accept presentations';
  end if;
  if exists (select 1 from public.session_chairs
    where session_id = new.session_id and report_submitted_at is not null) then
    raise exception 'Reopen the submitted report before changing its presentations';
  end if;
  if tg_op = 'INSERT' then
    if not app_private.is_chair() then raise exception 'Only the conference chair schedules presentations'; end if;
    select * into v_paper from public.papers where id = new.paper_id;
    if v_paper.id is null or v_paper.edition_year <> v_year
      or v_paper.status <> 'accepted' or v_paper.final_presentation <> v_type then
      raise exception 'Assign an accepted paper with a matching presentation type and edition';
    end if;
    if exists (
      select 1 from public.session_chairs sc
      left join public.profiles profile on profile.user_id = sc.user_id
      where sc.session_id = new.session_id
        and (v_paper.owner_id = sc.user_id or exists (
          select 1 from public.paper_authors author
          where author.paper_id = new.paper_id and profile.email is not null
            and lower(btrim(author.email)) = lower(btrim(profile.email))
        ))
    ) then raise exception 'A paper author cannot chair their own session'; end if;
    new.paper_title := v_paper.title;
    new.attendance := 'pending';
    new.award_recommended := false;
    new.chair_note := '';
    new.recorded_at := null;
  elsif not app_private.is_chair() then
    if not app_private.is_session_chair(new.session_id) then
      raise exception 'Only the assigned session chair may record this presentation';
    end if;
    if new.presenter_name is distinct from old.presenter_name then
      raise exception 'Only the conference chair may change the presenter';
    end if;
    new.recorded_at := now();
  else
    if new.attendance is distinct from old.attendance
      or new.award_recommended is distinct from old.award_recommended
      or new.chair_note is distinct from old.chair_note
      or new.recorded_at is distinct from old.recorded_at then
      raise exception 'The assigned session chair records attendance and recommendations';
    end if;
  end if;
  if new.attendance <> 'presented' and new.award_recommended then
    raise exception 'Only a presented paper can be recommended';
  end if;
  if app_private.session_chair_has_author_conflict(new.session_id,
    (select user_id from public.session_chairs where session_id = new.session_id)) then
    raise exception 'A paper author cannot chair their own session';
  end if;
  return new;
end;
$$;
create trigger guard_session_presentation before insert or update on public.session_presentations
  for each row execute function app_private.guard_session_presentation();

create function app_private.guard_session_presentation_delete() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.session_chairs
    where session_id = old.session_id and report_submitted_at is not null) then
    raise exception 'Reopen the submitted report before removing a presentation';
  end if;
  return old;
end;
$$;
create trigger guard_session_presentation_delete before delete on public.session_presentations
  for each row execute function app_private.guard_session_presentation_delete();

create function app_private.guard_scheduled_paper_decision() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'accepted' and (new.status <> 'accepted'
    or new.final_presentation is distinct from old.final_presentation)
    and exists (select 1 from public.session_presentations where paper_id = old.id) then
    raise exception 'Remove the paper from its session before changing the decision or presentation type';
  end if;
  return new;
end;
$$;
create trigger guard_scheduled_paper_decision before update on public.papers
  for each row execute function app_private.guard_scheduled_paper_decision();

alter table public.session_chairs enable row level security;
alter table public.session_presentations enable row level security;
create policy session_chairs_read on public.session_chairs for select to authenticated
  using (app_private.is_session_chair(session_id) or (select app_private.is_chair()));
create policy session_chairs_insert on public.session_chairs for insert to authenticated
  with check ((select app_private.is_chair()));
create policy session_chairs_update on public.session_chairs for update to authenticated
  using (app_private.is_session_chair(session_id) or (select app_private.is_chair()))
  with check (app_private.is_session_chair(session_id) or (select app_private.is_chair()));
create policy session_chairs_delete on public.session_chairs for delete to authenticated
  using ((select app_private.is_chair()));

create policy session_presentations_read on public.session_presentations for select to authenticated
  using ((select app_private.is_chair()) or app_private.is_session_chair(session_id));
create policy session_presentations_insert on public.session_presentations for insert to authenticated
  with check ((select app_private.is_chair()));
create policy session_presentations_update on public.session_presentations for update to authenticated
  using ((select app_private.is_chair()) or app_private.is_session_chair(session_id))
  with check ((select app_private.is_chair()) or app_private.is_session_chair(session_id));
create policy session_presentations_delete on public.session_presentations for delete to authenticated
  using ((select app_private.is_chair()));

create policy assigned_chairs_read_sessions on public.program_sessions for select to authenticated
  using (app_private.is_session_chair(id));

grant select, insert, update, delete on public.session_chairs, public.session_presentations to authenticated;
