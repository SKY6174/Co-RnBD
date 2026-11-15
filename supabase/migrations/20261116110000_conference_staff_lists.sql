-- Read-only participant lists for the organizing committee (operator request 2026-11-15):
-- 조직위원장(organizing_chair), 학술위원장(program_chair), 사무국(secretariat).
--
-- Security model
-- * Grants live in app_private (not exposed through the API) and are separate from
--   public.staff_roles, so a staff grant never carries chair powers.
-- * Only a chair can grant or revoke, only to an existing account with a verified email,
--   per conference year, with a mandatory expiry (at most 180 days after the event).
-- * Staff read lists only through four security-definer functions that return a fixed,
--   minimal set of columns. No table or RLS policy is opened: no PDFs, abstracts, review
--   text, reviewer↔paper mapping or co-author emails. Registration and fee-payment status
--   (amount, method, payment date) are included so the secretariat can follow payments.
-- * Every list read is written to an access log (who, which list, how many rows, when),
--   kept two years (개인정보의 안전성 확보조치 기준: 접속기록 1년 이상) and readable by the chair.

create table app_private.conference_staff (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  edition_year integer not null references public.conference_editions(year),
  staff_role text not null check (staff_role in ('organizing_chair', 'program_chair', 'secretariat')),
  granted_by uuid references auth.users(id) on delete set null,
  granted_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  revoked_by uuid references auth.users(id) on delete set null,
  check (expires_at > granted_at)
);
create unique index conference_staff_active_idx on app_private.conference_staff(user_id, edition_year) where revoked_at is null;
create index conference_staff_granted_by_idx on app_private.conference_staff(granted_by);
create index conference_staff_revoked_by_idx on app_private.conference_staff(revoked_by);
alter table app_private.conference_staff enable row level security;
revoke all on app_private.conference_staff from public, anon, authenticated, service_role;

create table app_private.staff_access_log (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  actor_email text not null,
  staff_role text not null,
  edition_year integer not null,
  list_name text not null,
  row_count integer not null,
  accessed_at timestamptz not null default now()
);
create index staff_access_log_time_idx on app_private.staff_access_log(edition_year, accessed_at desc);
create index staff_access_log_user_idx on app_private.staff_access_log(user_id);
alter table app_private.staff_access_log enable row level security;
revoke all on app_private.staff_access_log from public, anon, authenticated, service_role;

-- 'chair' for chairs, the active staff role otherwise, null when there is no access.
create function app_private.staff_access_role(p_year integer) returns text
language sql stable security definer set search_path = '' as $$
  select case when app_private.is_chair() then 'chair' else (
    select s.staff_role from app_private.conference_staff s join auth.users u on u.id = s.user_id
    where s.user_id = auth.uid() and s.edition_year = p_year and s.revoked_at is null
      and now() < s.expires_at and u.email_confirmed_at is not null
    limit 1) end;
$$;
revoke all on function app_private.staff_access_role(integer) from public, anon, authenticated;

create function app_private.log_staff_access(p_year integer, p_list text, p_rows integer) returns void
language plpgsql security definer set search_path = '' as $$
declare r text := app_private.staff_access_role(p_year);
begin
  if r is null then raise exception 'Staff list access required'; end if;
  insert into app_private.staff_access_log (user_id, actor_email, staff_role, edition_year, list_name, row_count)
    values (auth.uid(), coalesce((select lower(email) from auth.users where id = auth.uid()), ''), r, p_year, p_list, p_rows);
end; $$;
revoke all on function app_private.log_staff_access(integer, text, integer) from public, anon, authenticated;

-- Which access do I have? Used by the staff page; no data, no log entry.
create function public.staff_my_access(p_year integer)
returns table (staff_role text, expires_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select app_private.staff_access_role(p_year),
    (select s.expires_at from app_private.conference_staff s
      where s.user_id = auth.uid() and s.edition_year = p_year and s.revoked_at is null and now() < s.expires_at limit 1)
  where app_private.staff_access_role(p_year) is not null;
$$;

create function public.staff_list_registrations(p_year integer)
returns table (registration_no text, full_name text, affiliation text, department text, position_title text, email text,
  category text, attendance_days date[], status text, confirmed boolean, checked_in_at timestamptz, applied_at timestamptz,
  payment_status text, fee_amount integer, payment_method text, paid_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if app_private.staff_access_role(p_year) is null then raise exception 'Staff list access required'; end if;
  return query
    select upper(left(r.id::text, 8)), p.full_name, p.affiliation, p.department, p.position_title, p.email,
      r.category, r.attendance_days, r.status, r.status = 'confirmed', r.checked_in_at, r.created_at,
      coalesce(b.status, 'unpaid'), b.amount, b.payment_method, b.paid_at
    from public.attendee_registrations r
    join public.profiles p on p.user_id = r.user_id
    left join public.registration_billing b on b.registration_id = r.id
    where r.edition_year = p_year
    order by r.created_at;
  get diagnostics n = row_count;
  perform app_private.log_staff_access(p_year, 'registrations', n);
end; $$;

create function public.staff_list_submissions(p_year integer)
returns table (paper_no text, title text, track text, paper_type text, preferred_presentation text, status text,
  submitted_at timestamptz, submitter_name text, submitter_affiliation text, submitter_email text, authors text,
  reviewers_assigned integer, reviews_submitted integer)
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if app_private.staff_access_role(p_year) is null then raise exception 'Staff list access required'; end if;
  return query
    select upper(left(x.id::text, 8)), x.title, x.track, x.paper_type, x.preferred_presentation, x.status, x.submitted_at,
      p.full_name, p.affiliation, p.email,
      (select string_agg(a.full_name || coalesce(' (' || nullif(btrim(a.affiliation), '') || ')', ''), ', ' order by a.sort_order)
        from public.paper_authors a where a.paper_id = x.id),
      (select count(*)::integer from public.reviews v where v.paper_id = x.id and v.revoked_at is null
        and v.manuscript_submitted_at = x.submitted_at and v.review_state <> 'declined'),
      (select count(*)::integer from public.reviews v where v.paper_id = x.id and v.revoked_at is null
        and v.manuscript_submitted_at = x.submitted_at and v.review_state = 'submitted')
    from public.papers x
    left join public.profiles p on p.user_id = x.owner_id
    where x.edition_year = p_year and x.status <> 'draft'
    order by x.submitted_at nulls last, x.created_at;
  get diagnostics n = row_count;
  perform app_private.log_staff_access(p_year, 'submissions', n);
end; $$;

create function public.staff_list_reviewers(p_year integer)
returns table (track text, committee_role text, display_name text, email text, affiliation text, has_account boolean,
  active boolean, assigned integer, submitted integer, declined integer)
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if app_private.staff_access_role(p_year) is null then raise exception 'Staff list access required'; end if;
  return query
    select c.track, c.committee_role, c.display_name, c.email, p.affiliation, c.user_id is not null, c.active,
      (select count(*)::integer from public.reviews v join public.papers x on x.id = v.paper_id
        where v.reviewer_id = c.user_id and x.edition_year = p_year and v.revoked_at is null and v.manuscript_submitted_at = x.submitted_at),
      (select count(*)::integer from public.reviews v join public.papers x on x.id = v.paper_id
        where v.reviewer_id = c.user_id and x.edition_year = p_year and v.revoked_at is null and v.manuscript_submitted_at = x.submitted_at
          and v.review_state = 'submitted'),
      (select count(*)::integer from public.reviews v join public.papers x on x.id = v.paper_id
        where v.reviewer_id = c.user_id and x.edition_year = p_year and v.revoked_at is null and v.manuscript_submitted_at = x.submitted_at
          and v.review_state = 'declined')
    from public.review_committee c
    left join public.profiles p on p.user_id = c.user_id
    where c.edition_year = p_year
    order by c.track, c.committee_role, c.display_name;
  get diagnostics n = row_count;
  perform app_private.log_staff_access(p_year, 'reviewers', n);
end; $$;

create function public.staff_list_session_chairs(p_year integer)
returns table (session_title text, session_type text, starts_at timestamptz, ends_at timestamptz, room text, is_published boolean,
  chair_name text, chair_affiliation text, chair_email text, presentations integer, report_submitted_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if app_private.staff_access_role(p_year) is null then raise exception 'Staff list access required'; end if;
  return query
    select s.title, s.session_type, s.starts_at, s.ends_at, s.room, s.is_published,
      p.full_name, p.affiliation, p.email,
      (select count(*)::integer from public.session_presentations sp where sp.session_id = s.id),
      c.report_submitted_at
    from public.session_chairs c
    join public.program_sessions s on s.id = c.session_id
    left join public.profiles p on p.user_id = c.user_id
    where s.edition_year = p_year
    order by s.starts_at nulls last, s.title;
  get diagnostics n = row_count;
  perform app_private.log_staff_access(p_year, 'session_chairs', n);
end; $$;

-- Chair-only management.
create function public.chair_grant_staff(p_year integer, p_email text, p_role text, p_expires_at timestamptz default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare target uuid; event_end date; expiry timestamptz; saved uuid;
begin
  if auth.uid() is null or not app_private.is_chair() then raise exception 'Chair permission required'; end if;
  if p_role not in ('organizing_chair', 'program_chair', 'secretariat') then raise exception 'Unknown staff role'; end if;
  select end_date into event_end from public.conference_editions where year = p_year;
  if event_end is null then raise exception 'Unknown conference year'; end if;
  select id into target from auth.users where lower(email) = lower(btrim(p_email)) and email_confirmed_at is not null;
  if target is null then raise exception 'No verified account with this email. Ask the person to sign up and verify first.'; end if;
  expiry := coalesce(p_expires_at, ((event_end + 30)::timestamp at time zone 'Asia/Seoul'));
  if expiry <= now() or expiry > ((event_end + 180)::timestamp at time zone 'Asia/Seoul') then
    raise exception 'Expiry must be in the future and within 180 days after the conference';
  end if;
  update app_private.conference_staff set revoked_at = now(), revoked_by = auth.uid()
    where user_id = target and edition_year = p_year and revoked_at is null;
  insert into app_private.conference_staff (user_id, edition_year, staff_role, granted_by, expires_at)
    values (target, p_year, p_role, auth.uid(), expiry) returning id into saved;
  return saved;
end; $$;

create function public.chair_revoke_staff(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not app_private.is_chair() then raise exception 'Chair permission required'; end if;
  update app_private.conference_staff set revoked_at = now(), revoked_by = auth.uid() where id = p_id and revoked_at is null;
  if not found then raise exception 'Active staff grant not found'; end if;
end; $$;

create function public.chair_list_staff(p_year integer)
returns table (id uuid, full_name text, email text, staff_role text, granted_at timestamptz, expires_at timestamptz,
  revoked_at timestamptz, active boolean, last_access_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not app_private.is_chair() then raise exception 'Chair permission required'; end if;
  return query
    select s.id, p.full_name, lower(u.email), s.staff_role, s.granted_at, s.expires_at, s.revoked_at,
      s.revoked_at is null and now() < s.expires_at,
      (select max(l.accessed_at) from app_private.staff_access_log l where l.user_id = s.user_id and l.edition_year = p_year)
    from app_private.conference_staff s join auth.users u on u.id = s.user_id
    left join public.profiles p on p.user_id = s.user_id
    where s.edition_year = p_year
    order by s.revoked_at nulls first, s.granted_at desc;
end; $$;

create function public.chair_staff_access_log(p_year integer, p_limit integer default 100)
returns table (accessed_at timestamptz, actor_email text, staff_role text, list_name text, row_count integer)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not app_private.is_chair() then raise exception 'Chair permission required'; end if;
  return query
    select l.accessed_at, l.actor_email, l.staff_role, l.list_name, l.row_count
    from app_private.staff_access_log l where l.edition_year = p_year
    order by l.accessed_at desc limit least(greatest(coalesce(p_limit, 100), 1), 500);
end; $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.staff_my_access(integer)', 'public.staff_list_registrations(integer)', 'public.staff_list_submissions(integer)',
    'public.staff_list_reviewers(integer)', 'public.staff_list_session_chairs(integer)',
    'public.chair_grant_staff(integer, text, text, timestamptz)', 'public.chair_revoke_staff(uuid)',
    'public.chair_list_staff(integer)', 'public.chair_staff_access_log(integer, integer)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- Access logs: keep two years, then delete.
select cron.schedule('staff-access-log-retention', '20 3 * * *',
  $$delete from app_private.staff_access_log where accessed_at < now() - interval '2 years'$$);
