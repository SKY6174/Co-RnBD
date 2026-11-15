-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-presenter-registration.sql
begin;
do $$
begin
  if exists (select 1 from auth.users where email not like '%@example.test') then
    raise exception 'Refusing to run: non-synthetic accounts present';
  end if;
end $$;

create temp table fx (k text primary key, v uuid) on commit drop;
grant select on fx to authenticated;

do $$
declare chair uuid := gen_random_uuid(); owner uuid := gen_random_uuid(); coauthor uuid := gen_random_uuid();
  member uuid := gen_random_uuid(); rejected_author uuid := gen_random_uuid();
  r1 uuid := gen_random_uuid(); r2 uuid := gen_random_uuid(); p uuid; path text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data)
  select id, email, 'authenticated', 'authenticated', now(), '{}' from (values
    (chair,'pr-chair@example.test'),(owner,'pr-owner@example.test'),(coauthor,'pr-coauthor@example.test'),
    (member,'pr-member@example.test'),(rejected_author,'pr-rejected@example.test'),
    (r1,'pr-r1@example.test'),(r2,'pr-r2@example.test')) v(id,email);
  update public.profiles set full_name = '합성 사용자', affiliation = '로컬 검증 기관'
    where user_id in (chair, owner, coauthor, member, rejected_author, r1, r2);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  update public.conference_settings set submissions_open = true, submission_deadline = null where edition_year = 2026;

  foreach p in array array[gen_random_uuid(), gen_random_uuid()] loop
    perform set_config('request.jwt.claim.sub', (case when exists (select 1 from fx where k = 'accepted') then rejected_author else owner end)::text, true);
    insert into public.papers (id, owner_id, title, abstract, track, paper_type, preferred_presentation, edition_year, contact_name, contact_email)
      values (p, auth.uid(), 'LOCAL PRESENTER FIXTURE', 'Synthetic presenter fixture only.', 'master_eng', 'research', 'oral', 2026, 'Author',
        (select email from auth.users where id = auth.uid()));
    insert into public.paper_authors (paper_id, sort_order, full_name, affiliation, email) values
      (p, 1, 'Author', 'Local', (select email from auth.users where id = auth.uid())),
      (p, 2, 'Coauthor', 'Local', case when exists (select 1 from fx where k = 'accepted') then 'nobody@example.test' else 'PR-Coauthor@example.test' end);
    path := auth.uid()::text || '/' || p::text || '/fixture.pdf';
    insert into storage.objects (bucket_id, name, owner_id, metadata) values ('paper-pdfs', path, auth.uid()::text, '{"mimetype":"application/pdf","size":100}');
    insert into public.paper_files (paper_id, storage_path, original_name, version, uploaded_by, file_stage) values (p, path, 'fixture.pdf', 1, auth.uid(), 'submission');
    update public.papers set status = 'submitted' where id = p;
    perform set_config('request.jwt.claim.sub', chair::text, true);
    perform public.chair_assign_reviewer(p, r1, null, '');
    perform public.chair_assign_reviewer(p, r2, null, '');
    update public.papers set status = case when exists (select 1 from fx where k = 'accepted') then 'rejected' else 'accepted' end,
      decision_note = '로컬 검증 판정', decision_exception_reason = '로컬 검증 예외 판정' where id = p;
    insert into fx values (case when exists (select 1 from fx where k = 'accepted') then 'rejected' else 'accepted' end, p);
  end loop;

  -- General registration closed; presenter registration open until the final deadline.
  update public.conference_settings set registration_open = true, registration_deadline = now() - interval '1 hour',
    final_deadline = now() + interval '7 days' where edition_year = 2026;
  insert into fx values ('chair', chair), ('owner', owner), ('coauthor', coauthor), ('member', member), ('rejected_author', rejected_author);
  raise notice 'PASS: accepted paper (owner + co-author), rejected paper; general registration closed';
end $$;

set local role authenticated;
do $$
declare failed boolean;
  function_result boolean;
begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'owner')::text, true);
  assert public.presenter_registration_eligible(2026), 'Owner should be eligible';
  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days)
    values ((select v from fx where k = 'owner'), 2026, 'presenter', array[date '2027-01-20']);
  raise notice 'PASS: accepted-paper owner registers as presenter after general registration closed';

  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'coauthor')::text, true);
  assert public.presenter_registration_eligible(2026), 'Listed co-author should be eligible';
  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days)
    values ((select v from fx where k = 'coauthor'), 2026, 'presenter', array[date '2027-01-21']);
  raise notice 'PASS: listed co-author (case-insensitive email) registers as presenter';

  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'member')::text, true);
  assert not public.presenter_registration_eligible(2026), 'Member must not be eligible';
  failed := false;
  begin insert into public.attendee_registrations (user_id, edition_year, category, attendance_days)
    values ((select v from fx where k = 'member'), 2026, 'presenter', array[date '2027-01-20']);
  exception when others then failed := sqlerrm = 'Presenter registration requires an accepted paper'; end;
  assert failed, 'Non-author registered as presenter';
  failed := false;
  begin insert into public.attendee_registrations (user_id, edition_year, category, attendance_days)
    values ((select v from fx where k = 'member'), 2026, 'faculty', array[date '2027-01-20']);
  exception when others then failed := sqlerrm = 'Registration is closed'; end;
  assert failed, 'General registration accepted after its deadline';
  raise notice 'PASS: members cannot pick presenter, and general registration stays closed';

  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'rejected_author')::text, true);
  assert not public.presenter_registration_eligible(2026), 'Rejected-paper author must not be eligible';
  failed := false;
  begin insert into public.attendee_registrations (user_id, edition_year, category, attendance_days)
    values ((select v from fx where k = 'rejected_author'), 2026, 'presenter', array[date '2027-01-20']);
  exception when others then failed := sqlerrm = 'Presenter registration requires an accepted paper'; end;
  assert failed, 'Rejected-paper author registered as presenter';
  raise notice 'PASS: authors of rejected papers are not presenters';
end $$;
reset role;

do $$ begin
  update public.conference_settings set final_deadline = now() - interval '1 minute' where edition_year = 2026;
end $$;
set local role authenticated;
do $$
declare failed boolean := false;
begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'owner')::text, true);
  update public.attendee_registrations set status = 'cancelled' where user_id = (select v from fx where k = 'owner');
  begin update public.attendee_registrations set status = 'applied' where user_id = (select v from fx where k = 'owner');
  exception when others then failed := sqlerrm = 'Registration is closed'; end;
  assert failed, 'Presenter re-applied after the presenter deadline';
  raise notice 'PASS: after the presenter deadline, cancel works but re-applying is closed';
end $$;
reset role;

do $$ begin
  assert exists (select 1 from public.attendee_registrations r join fx on fx.v = r.user_id and fx.k = 'coauthor' where r.category = 'presenter');
  raise notice 'PASS: presenter registrations stored with category presenter';
end $$;
rollback;
