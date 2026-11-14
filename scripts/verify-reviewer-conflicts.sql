-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-reviewer-conflicts.sql
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
  coauthor uuid := gen_random_uuid(); contact uuid := gen_random_uuid();
  clean1 uuid := gen_random_uuid(); clean2 uuid := gen_random_uuid(); decliner uuid := gen_random_uuid();
  paper uuid := gen_random_uuid(); review uuid; path text; ok boolean;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data) values
    (chair, 'coi-chair@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (author, 'coi-author@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (coauthor, 'COI-Coauthor@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (contact, 'coi-contact@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (clean1, 'coi-clean1@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (clean2, 'coi-clean2@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (decliner, 'coi-decliner@example.test', 'authenticated', 'authenticated', now(), '{}');
  update public.profiles set full_name = '합성 ' || split_part(email, '@', 1), affiliation = '로컬 검증 기관'
    where user_id in (chair, author, coauthor, contact, clean1, clean2, decliner);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  update public.conference_settings set submissions_open = true, submission_deadline = null where edition_year = 2026;

  perform set_config('request.jwt.claim.sub', author::text, true);
  insert into public.papers (id, owner_id, title, abstract, track, paper_type, preferred_presentation, edition_year, contact_name, contact_email)
    values (paper, author, 'LOCAL REVIEWER CONFLICT FIXTURE', 'Synthetic reviewer conflict fixture only.', 'master_eng', 'research', 'oral', 2026,
      'Contact person', 'COI-Contact@example.test');
  insert into public.paper_authors (paper_id, sort_order, full_name, affiliation, email) values
    (paper, 1, 'Author', 'Local', 'coi-author@example.test'),
    (paper, 2, 'Coauthor', 'Local', 'coi-coauthor@EXAMPLE.test');
  path := author::text || '/' || paper::text || '/submission/fixture.pdf';
  insert into storage.objects (bucket_id, name, owner_id, metadata)
    values ('paper-pdfs', path, author::text, '{"mimetype":"application/pdf","size":100}');
  insert into public.paper_files (paper_id, storage_path, original_name, version, uploaded_by, file_stage)
    values (paper, path, 'fixture.pdf', 1, author, 'submission');
  update public.papers set status = 'submitted' where id = paper;
  raise notice 'PASS: synthetic submitted paper with co-author and contact emails';

  perform set_config('request.jwt.claim.sub', chair::text, true);
  foreach review in array array[author, coauthor, contact] loop
    ok := false;
    begin
      perform public.chair_assign_reviewer(paper, review, null, '');
    exception when others then ok := sqlerrm in ('Reviewer is an author of this paper', 'Reviewer is the contact person of this paper');
      if not ok then raise exception 'Unexpected error for %: %', review, sqlerrm; end if;
    end;
    assert ok, 'Conflicted reviewer was assigned';
  end loop;
  raise notice 'PASS: owner, co-author and contact (case-insensitive) are refused';

  review := public.chair_assign_reviewer(paper, decliner, null, '');
  perform public.chair_assign_reviewer(paper, clean1, null, '');
  raise notice 'PASS: unrelated reviewers are assigned';

  perform set_config('request.jwt.claim.sub', decliner::text, true);
  update public.reviews set review_state = 'declined', decline_reason = '지도교수와 공동 과제 수행' where id = review;
  assert (select review_state from public.reviews where id = review) = 'declined';

  perform set_config('request.jwt.claim.sub', chair::text, true);
  ok := false;
  begin
    perform public.chair_assign_reviewer(paper, decliner, null, '');
  exception when others then ok := sqlerrm = 'Reviewer declared a conflict for this paper';
    if not ok then raise exception 'Unexpected error for decliner: %', sqlerrm; end if;
  end;
  assert ok, 'Reviewer who declared a conflict was reassigned';
  raise notice 'PASS: a reviewer who declared a conflict cannot be reassigned';

  -- Simulate a later manuscript version: same paper, new submitted_at.
  update public.reviews set revoked_at = now(), revoked_by = chair, revocation_reason = '수정본 재심사' where paper_id = paper and revoked_at is null;
  update public.papers set submitted_at = now() + interval '1 minute' where id = paper;
  ok := false;
  begin
    perform public.chair_assign_reviewer(paper, decliner, null, '');
  exception when others then ok := sqlerrm = 'Reviewer declared a conflict for this paper';
    if not ok then raise exception 'Unexpected error on new version: %', sqlerrm; end if;
  end;
  assert ok, 'Declared conflict must carry over to a later manuscript version';
  perform public.chair_assign_reviewer(paper, clean2, null, '');
  raise notice 'PASS: declared conflict carries over to a later version; unrelated reviewer still assignable';
end $$;
rollback;
