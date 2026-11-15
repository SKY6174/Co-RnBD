-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-presenter-status.sql
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
  owner2 uuid := gen_random_uuid(); member uuid := gen_random_uuid();
  r1 uuid := gen_random_uuid(); r2 uuid := gen_random_uuid(); p uuid; path text; i integer := 0;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data)
  select id, email, 'authenticated', 'authenticated', now(), '{}' from (values
    (chair,'ps-chair@example.test'),(owner,'ps-owner@example.test'),(coauthor,'ps-coauthor@example.test'),
    (owner2,'ps-owner2@example.test'),(member,'ps-member@example.test'),
    (r1,'ps-r1@example.test'),(r2,'ps-r2@example.test')) v(id,email);
  update public.profiles set full_name = '합성 사용자', affiliation = '로컬 검증 기관'
    where user_id in (chair, owner, coauthor, owner2, member, r1, r2);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  update public.conference_settings set submissions_open = true, submission_deadline = null,
    registration_open = true, registration_deadline = now() + interval '7 days', final_deadline = now() + interval '7 days'
    where edition_year = 2026;

  -- Paper A (owner + co-author with account + author without account); Paper B (owner2 only); Paper C rejected.
  foreach p in array array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid()] loop
    i := i + 1;
    perform set_config('request.jwt.claim.sub', (case i when 1 then owner when 2 then owner2 else member end)::text, true);
    insert into public.papers (id, owner_id, title, abstract, track, paper_type, preferred_presentation, edition_year, contact_name, contact_email)
      values (p, auth.uid(), 'LOCAL STATUS ' || i, 'Synthetic status fixture only.', 'master_eng', 'research', 'oral', 2026, 'Author',
        (select email from auth.users where id = auth.uid()));
    insert into public.paper_authors (paper_id, sort_order, full_name, affiliation, email)
      values (p, 1, 'First', 'Local', (select email from auth.users where id = auth.uid()));
    if i = 1 then
      insert into public.paper_authors (paper_id, sort_order, full_name, affiliation, email) values
        (p, 2, 'Coauthor', 'Local', 'PS-Coauthor@example.test'), (p, 3, 'No Account', 'Local', 'nobody@example.test');
    end if;
    path := auth.uid()::text || '/' || p::text || '/fixture.pdf';
    insert into storage.objects (bucket_id, name, owner_id, metadata) values ('paper-pdfs', path, auth.uid()::text, '{"mimetype":"application/pdf","size":100}');
    insert into public.paper_files (paper_id, storage_path, original_name, version, uploaded_by, file_stage) values (p, path, 'fixture.pdf', 1, auth.uid(), 'submission');
    update public.papers set status = 'submitted' where id = p;
    perform set_config('request.jwt.claim.sub', chair::text, true);
    perform public.chair_assign_reviewer(p, r1, null, '');
    perform public.chair_assign_reviewer(p, r2, null, '');
    update public.papers set status = case when i = 3 then 'rejected' else 'accepted' end,
      decision_note = '로컬 검증 판정', decision_exception_reason = '로컬 검증 예외 판정' where id = p;
    insert into fx values ('p' || i, p);
  end loop;

  -- Co-author registers as presenter; owner2 registers in a general category.
  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days)
    values (coauthor, 2026, 'presenter', array[date '2027-01-20']), (owner2, 2026, 'faculty', array[date '2027-01-21']);
  insert into fx values ('chair', chair), ('member', member), ('coauthor', coauthor), ('owner', owner);
  raise notice 'PASS: two accepted papers, one rejected; one presenter and one general registration';
end $$;

set local role authenticated;
do $$
declare failed boolean := false; n integer;
begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'member')::text, true);
  begin perform * from public.chair_presenter_status(2026);
  exception when others then failed := sqlerrm = 'Only the chair can view presenter status'; end;
  assert failed, 'Non-chair read presenter status';
  raise notice 'PASS: non-chair members are refused';

  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'chair')::text, true);
  select count(*) into n from public.chair_presenter_status(2026);
  assert n = 4, 'Expected 4 author rows (3 for paper 1, 1 for paper 2), got ' || n;
  assert not exists (select 1 from public.chair_presenter_status(2026) where paper_id = (select v from fx where k = 'p3')), 'Rejected paper listed';
  assert (select registration_category from public.chair_presenter_status(2026) where author_email = 'PS-Coauthor@example.test') = 'presenter',
    'Co-author presenter registration not matched case-insensitively';
  assert (select not has_account and registration_id is null from public.chair_presenter_status(2026) where author_email = 'nobody@example.test'),
    'Author without an account misreported';
  assert (select has_account and registration_id is null from public.chair_presenter_status(2026) where author_email = 'ps-owner@example.test'),
    'Unregistered owner misreported';
  assert (select registration_category from public.chair_presenter_status(2026) where author_email = 'ps-owner2@example.test') = 'faculty',
    'General registration of owner2 not shown';
  raise notice 'PASS: chair sees each accepted paper''s authors with account and registration state';
end $$;
reset role;

-- An owner who is not in the author list still appears once.
do $$ begin
  delete from public.paper_authors where paper_id = (select v from fx where k = 'p1') and sort_order = 1;
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'chair')::text, true);
end $$;
set local role authenticated;
do $$ begin
  assert (select count(*) from public.chair_presenter_status(2026) where paper_id = (select v from fx where k = 'p1')) = 3,
    'Owner missing when not a listed author';
  assert exists (select 1 from public.chair_presenter_status(2026) where paper_id = (select v from fx where k = 'p1') and sort_order = 0),
    'Owner row not added';
  raise notice 'PASS: submitting account shown even when not a listed author';
end $$;
reset role;
rollback;
