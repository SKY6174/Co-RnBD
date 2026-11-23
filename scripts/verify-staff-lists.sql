-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-staff-lists.sql
begin;
do $$
begin
  if exists (select 1 from auth.users where email not like '%@example.test') then
    raise exception 'Refusing to run: non-synthetic accounts present';
  end if;
end $$;

create temp table fx (k text primary key, v uuid) on commit drop;
grant select, insert on fx to authenticated;

do $$
declare chair uuid := gen_random_uuid(); sec uuid := gen_random_uuid(); member uuid := gen_random_uuid();
  unverified uuid := gen_random_uuid(); att uuid := gen_random_uuid(); reg uuid;
  reviewing uuid := gen_random_uuid();
  abstract text := repeat('로컬 검증용 합성 초록입니다. ', 5);
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data) values
    (chair, 'st-chair@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (sec, 'ST-Secretariat@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (member, 'st-member@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (unverified, 'st-unverified@example.test', 'authenticated', 'authenticated', null, '{}'),
    (att, 'st-attendee@example.test', 'authenticated', 'authenticated', now(), '{}');
  update public.profiles set full_name = '합성 사용자', affiliation = '로컬 검증 기관' where user_id in (chair, sec, member, unverified, att);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  update public.conference_settings set registration_open = true, registration_deadline = now() + interval '7 days' where edition_year = 2026;
  perform set_config('request.jwt.claim.sub', att::text, true);
  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days)
    values (att, 2026, 'faculty', array[date '2027-01-20']) returning id into reg;
  perform set_config('request.jwt.claim.sub', chair::text, true);
  update public.attendee_registrations set status = 'confirmed' where id = reg;
  insert into public.registration_billing (registration_id, amount, status, payment_method, paid_at, verified, updated_by)
    values (reg, 200000, 'paid', 'transfer', now(), true, chair);

  alter table public.papers disable trigger user;
  insert into public.papers (id, owner_id, edition_year, title, abstract, track, paper_type, preferred_presentation, final_presentation, status, contact_name, contact_email, submitted_at)
  values
    (gen_random_uuid(), att, 2026, '합성 채택', abstract, 'master_eng', 'research', 'oral', 'poster', 'accepted', '합성', 'st-attendee@example.test', now()),
    (reviewing, att, 2026, '합성 심사', abstract, 'master_eng', 'research', 'oral', null, 'under_review', '합성', 'st-attendee@example.test', now()),
    (gen_random_uuid(), att, 2026, '합성 초안', abstract, 'master_eng', 'research', 'poster', null, 'draft', '합성', 'st-attendee@example.test', null);
  alter table public.papers enable trigger user;
  alter table public.reviews disable trigger user;
  insert into public.reviews (paper_id, reviewer_id, review_state, manuscript_submitted_at, recommendation, comments, conflict_confirmed, submitted_at)
    values (reviewing, member, 'assigned', now(), null, '', false, null),
      (reviewing, member, 'submitted', now() - interval '1 day', 'accept', '합성 심사 의견', true, now());
  alter table public.reviews enable trigger user;
  insert into fx values ('chair', chair), ('sec', sec), ('member', member), ('att', att);
end $$;

set local role anon;
do $$
declare failed boolean := false;
begin
  begin perform * from public.staff_list_registrations(2026); exception when insufficient_privilege then failed := true; end;
  assert failed, 'anon executed a staff list';
  raise notice 'PASS: anonymous visitors cannot call staff list functions';
end $$;
reset role;

set local role authenticated;
do $$
declare failed boolean; f text; gid uuid;
begin
  -- A member without a grant gets nothing and cannot grant itself.
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'member')::text, true);
  foreach f in array array['staff_list_registrations', 'staff_list_submissions', 'staff_list_reviewers', 'staff_list_session_chairs'] loop
    failed := false;
    begin execute format('select count(*) from public.%I(2026)', f); exception when others then failed := sqlerrm = 'Staff list access required'; end;
    assert failed, f || ' readable without a grant';
  end loop;
  assert not exists (select 1 from public.staff_my_access(2026)), 'Member reported as staff';
  failed := false;
  begin perform public.chair_grant_staff(2026, 'st-member@example.test', 'secretariat'); exception when others then failed := sqlerrm = 'Chair permission required'; end;
  assert failed, 'Member granted itself';
  failed := false;
  begin perform count(*) from app_private.conference_staff; exception when insufficient_privilege then failed := true; end;
  assert failed, 'Grant table readable';
  raise notice 'PASS: without a grant every list is refused, self-grant is refused and private tables are closed';

  -- Chair grants; unverified accounts and out-of-range expiries are refused.
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'chair')::text, true);
  failed := false;
  begin perform public.chair_grant_staff(2026, 'st-unverified@example.test', 'secretariat'); exception when others then failed := sqlerrm like 'No verified account%'; end;
  assert failed, 'Unverified account granted';
  failed := false;
  begin perform public.chair_grant_staff(2026, 'st-secretariat@example.test', 'secretariat', now() + interval '2 years'); exception when others then failed := sqlerrm like 'Expiry must be%'; end;
  assert failed, 'Expiry beyond 180 days accepted';
  failed := false;
  begin perform public.chair_grant_staff(2026, 'st-secretariat@example.test', 'chair'); exception when others then failed := sqlerrm = 'Unknown staff role'; end;
  assert failed, 'Chair role granted through staff grant';
  gid := public.chair_grant_staff(2026, ' ST-Secretariat@example.test ', 'secretariat');
  insert into fx values ('grant', gid);
  raise notice 'PASS: chair grants only to verified accounts, known roles and bounded expiry';
end $$;

do $$
declare r record; n integer;
begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'sec')::text, true);
  assert (select staff_role from public.staff_my_access(2026)) = 'secretariat';
  select * into r from public.staff_list_registrations(2026) where email = 'st-attendee@example.test';
  assert r.status = 'confirmed' and r.confirmed and r.payment_status = 'paid' and r.fee_amount = 200000 and r.payment_method = 'transfer'
    and r.paid_at is not null, 'Registration/payment status incomplete';
  select count(*) as submissions,
    count(*) filter (where status = 'accepted' and preferred_presentation = 'oral' and final_presentation = 'poster') as accepted,
    count(*) filter (where status = 'under_review' and final_presentation is null and reviewers_assigned = 1 and reviews_submitted = 0) as reviewing
    into r from public.staff_list_submissions(2026);
  assert r.submissions = 2 and r.accepted = 1 and r.reviewing = 1, 'Draft, current submission progress or final presentation incorrect';
  select count(*) into n from public.staff_list_reviewers(2026);
  select count(*) into n from public.staff_list_session_chairs(2026);
  raise notice 'PASS: secretariat sees registration status, fee amount, method and payment date, and the other three lists';

  assert not app_private.is_chair(), 'Staff grant gave chair power';
  assert (select count(*) from public.attendee_registrations) = 0, 'Staff can read registrations directly';
  raise notice 'PASS: the grant gives no chair power and no direct table access';

  begin perform * from public.staff_list_registrations(2027); raise exception 'Other year readable';
  exception when others then assert sqlerrm = 'Staff list access required', sqlerrm; end;
  begin perform public.chair_list_staff(2026); raise exception 'Staff read grant list';
  exception when others then assert sqlerrm = 'Chair permission required', sqlerrm; end;
  begin perform * from public.chair_staff_access_log(2026); raise exception 'Staff read access log';
  exception when others then assert sqlerrm = 'Chair permission required', sqlerrm; end;
  raise notice 'PASS: a 2026 grant does not open 2027, the grant list or the access log';
end $$;
reset role;

do $$ begin
  assert (select count(*) from app_private.staff_access_log where actor_email = 'st-secretariat@example.test' and staff_role = 'secretariat') = 4,
    'Expected 4 logged reads';
  assert (select row_count from app_private.staff_access_log where list_name = 'registrations' and actor_email = 'st-secretariat@example.test') = 1;
  raise notice 'PASS: each list read is logged with actor, role, list and row count';
end $$;

set local role authenticated;
do $$
declare failed boolean := false;
begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'chair')::text, true);
  assert (select count(*) from public.chair_staff_access_log(2026)) = 4, 'Chair cannot see the log';
  assert (select active from public.chair_list_staff(2026) where email = 'st-secretariat@example.test');
  perform public.chair_revoke_staff((select v from fx where k = 'grant'));
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'sec')::text, true);
  begin perform * from public.staff_list_registrations(2026); exception when others then failed := sqlerrm = 'Staff list access required'; end;
  assert failed, 'Revoked staff still reads';
  raise notice 'PASS: chair sees the log; revoking ends access immediately';
end $$;
reset role;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'chair')::text, true);
  perform public.chair_grant_staff(2026, 'st-secretariat@example.test', 'program_chair');
  update app_private.conference_staff set granted_at = now() - interval '2 days', expires_at = now() - interval '1 day'
    where user_id = (select v from fx where k = 'sec') and revoked_at is null;
end $$;
set local role authenticated;
do $$
declare failed boolean := false;
begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'sec')::text, true);
  begin perform * from public.staff_list_registrations(2026); exception when others then failed := sqlerrm = 'Staff list access required'; end;
  assert failed, 'Expired grant still reads';
  raise notice 'PASS: an expired grant gives no access';
end $$;
reset role;

do $$ begin
  assert exists (select 1 from cron.job where jobname = 'staff-access-log-retention');
  raise notice 'PASS: access-log retention job registered';
end $$;
rollback;
