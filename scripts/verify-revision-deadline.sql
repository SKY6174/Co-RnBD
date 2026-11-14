-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-revision-deadline.sql
begin;
do $$
begin
  if exists (select 1 from auth.users where email not like '%@example.test') then
    raise exception 'Refusing to run: non-synthetic accounts present';
  end if;
end $$;

do $$
declare
  chair uuid := gen_random_uuid(); author uuid := gen_random_uuid();
  rev1 uuid := gen_random_uuid(); rev2 uuid := gen_random_uuid();
  paper uuid := gen_random_uuid(); path text; failed boolean;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data) values
    (chair, 'rev-chair@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (author, 'rev-author@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (rev1, 'rev-reviewer1@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (rev2, 'rev-reviewer2@example.test', 'authenticated', 'authenticated', now(), '{}');
  update public.profiles set full_name = '합성 사용자', affiliation = '로컬 검증 기관' where user_id in (chair, author, rev1, rev2);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  update public.conference_settings set submissions_open = true, submission_deadline = null, revision_deadline = null where edition_year = 2026;

  perform set_config('request.jwt.claim.sub', author::text, true);
  insert into public.papers (id, owner_id, title, abstract, track, paper_type, preferred_presentation, edition_year, contact_name, contact_email)
    values (paper, author, 'LOCAL REVISION DEADLINE FIXTURE', 'Synthetic revision deadline fixture only.', 'master_eng', 'research', 'oral', 2026,
      'Author', 'rev-author@example.test');
  insert into public.paper_authors (paper_id, sort_order, full_name, affiliation, email) values (paper, 1, 'Author', 'Local', 'rev-author@example.test');
  path := author::text || '/' || paper::text || '/submission/fixture.pdf';
  insert into storage.objects (bucket_id, name, owner_id, metadata) values ('paper-pdfs', path, author::text, '{"mimetype":"application/pdf","size":100}');
  insert into public.paper_files (paper_id, storage_path, original_name, version, uploaded_by, file_stage) values (paper, path, 'fixture.pdf', 1, author, 'submission');
  update public.papers set status = 'submitted' where id = paper;

  -- Chair requests a revision; then close new submissions to prove revisions use their own deadline.
  perform set_config('request.jwt.claim.sub', chair::text, true);
  perform public.chair_assign_reviewer(paper, rev1, null, '');
  perform public.chair_assign_reviewer(paper, rev2, null, '');
  update public.papers set status = 'revision', decision_note = '로컬 검증 수정 요청', decision_exception_reason = '로컬 검증 예외 판정' where id = paper;
  update public.conference_settings set submission_deadline = now() - interval '1 day', revision_deadline = now() - interval '1 minute' where edition_year = 2026;
  raise notice 'PASS: paper in revision; submission window closed; revision deadline passed';

  perform set_config('request.jwt.claim.sub', author::text, true);
  failed := false;
  begin update public.papers set status = 'submitted' where id = paper;
  exception when others then failed := sqlerrm = 'The revision resubmission deadline has passed';
    if not failed then raise exception 'Unexpected error: %', sqlerrm; end if;
  end;
  assert failed, 'Author resubmitted after the revision deadline';
  assert (select status from public.papers where id = paper) = 'revision';
  update public.papers set title = 'LOCAL REVISION DEADLINE FIXTURE (edited)' where id = paper;
  raise notice 'PASS: author cannot resubmit after the revision deadline, but can still edit the draft';

  perform set_config('request.jwt.claim.sub', chair::text, true);
  update public.conference_settings set revision_deadline = now() + interval '1 day' where edition_year = 2026;
  perform set_config('request.jwt.claim.sub', author::text, true);
  update public.papers set status = 'submitted' where id = paper;
  assert (select status from public.papers where id = paper) = 'submitted';
  raise notice 'PASS: author resubmits before the revision deadline even though new submissions are closed';

  perform set_config('request.jwt.claim.sub', chair::text, true);
  -- Same transaction keeps now() fixed, so the two existing assignments still count as current.
  update public.papers set status = 'revision', decision_note = '로컬 검증 2차 수정 요청', decision_exception_reason = '로컬 검증 예외 판정' where id = paper;
  update public.conference_settings set revision_deadline = null where edition_year = 2026;
  perform set_config('request.jwt.claim.sub', author::text, true);
  update public.papers set status = 'submitted' where id = paper;
  assert (select status from public.papers where id = paper) = 'submitted';
  raise notice 'PASS: no revision deadline keeps the previous unlimited behaviour';

  assert exists (select 1 from information_schema.columns where table_schema = 'public'
    and table_name = 'conference_settings' and column_name = 'revision_deadline');
end $$;

set local role anon;
do $$ begin
  perform revision_deadline from public.conference_settings where edition_year = 2026;
  raise notice 'PASS: anon can read revision_deadline for the public portal';
end $$;
reset role;
rollback;
