-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-re-review-deadline.sql
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
declare chair uuid := gen_random_uuid(); author uuid := gen_random_uuid();
  r1 uuid := gen_random_uuid(); r2 uuid := gen_random_uuid(); r3 uuid := gen_random_uuid();
  paper uuid := gen_random_uuid(); path text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data)
  select id, email, 'authenticated', 'authenticated', now(), '{}' from (values
    (chair, 'rr-chair@example.test'), (author, 'rr-author@example.test'),
    (r1, 'rr-r1@example.test'), (r2, 'rr-r2@example.test'), (r3, 'rr-r3@example.test')) v(id, email);
  update public.profiles set full_name = '합성 사용자', affiliation = '로컬 검증 기관', expertise_tracks = array['master_eng']
    where user_id in (chair, author, r1, r2, r3);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  update public.conference_settings set submissions_open = true, submission_deadline = null, revision_deadline = null,
    reviews_open = true, review_deadline = now() - interval '1 minute', re_review_deadline = now() + interval '1 day'
    where edition_year = 2026;

  perform set_config('request.jwt.claim.sub', author::text, true);
  insert into public.papers (id, owner_id, title, abstract, track, paper_type, preferred_presentation, edition_year, contact_name, contact_email)
    values (paper, author, 'LOCAL RE-REVIEW FIXTURE', 'Synthetic re-review deadline fixture only.', 'master_eng', 'research', 'oral', 2026,
      'Author', 'rr-author@example.test');
  insert into public.paper_authors (paper_id, sort_order, full_name, affiliation, email) values (paper, 1, 'Author', 'Local', 'rr-author@example.test');
  path := author::text || '/' || paper::text || '/submission/fixture.pdf';
  insert into storage.objects (bucket_id, name, owner_id, metadata) values ('paper-pdfs', path, author::text, '{"mimetype":"application/pdf","size":100}');
  insert into public.paper_files (paper_id, storage_path, original_name, version, uploaded_by, file_stage) values (paper, path, 'fixture.pdf', 1, author, 'submission');
  update public.papers set status = 'submitted' where id = paper;
  perform set_config('request.jwt.claim.sub', chair::text, true);
  perform public.chair_assign_reviewer(paper, r1, null, '');
  perform public.chair_assign_reviewer(paper, r2, null, '');
  insert into fx values ('chair', chair), ('author', author), ('r1', r1), ('r2', r2), ('r3', r3), ('paper', paper);
  raise notice 'PASS: first-round paper under review; review deadline passed, re-review deadline open';
end $$;

set local role authenticated;
do $$
declare failed boolean := false;
begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'r1')::text, true);
  assert not exists (select 1 from public.my_re_review_ids()), 'First-round review reported as re-review';
  begin
    update public.reviews set review_state = 'submitted', recommendation = 'accept', comments = '1차 의견', conflict_confirmed = true
      where paper_id = (select v from fx where k = 'paper') and reviewer_id = (select v from fx where k = 'r1');
  exception when others then failed := sqlerrm = 'Review submission is closed';
    if not failed then raise exception 'Unexpected error: %', sqlerrm; end if;
  end;
  assert failed, 'First-round review accepted after review_deadline';
  raise notice 'PASS: first-round reviews close at review_deadline even when the re-review deadline is open';
end $$;
reset role;

-- Revision requested and resubmitted; a new reviewer is assigned to the revised manuscript.
do $$ begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'chair')::text, true);
  update public.papers set status = 'revision', decision_note = '로컬 수정 요청', decision_exception_reason = '로컬 검증 예외 판정'
    where id = (select v from fx where k = 'paper');
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'author')::text, true);
  update public.papers set status = 'submitted' where id = (select v from fx where k = 'paper');
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'chair')::text, true);
  -- Same transaction keeps submitted_at, so the first two assignments stay current; replace one with r3.
  perform public.chair_assign_reviewer((select v from fx where k = 'paper'), (select v from fx where k = 'r3'),
    (select id from public.reviews where paper_id = (select v from fx where k = 'paper') and reviewer_id = (select v from fx where k = 'r2')), '로컬 교체');
  assert (select status from public.papers where id = (select v from fx where k = 'paper')) = 'under_review';
end $$;

set local role authenticated;
do $$
declare failed boolean := false; review uuid;
begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'r3')::text, true);
  select id into review from public.reviews where paper_id = (select v from fx where k = 'paper') and reviewer_id = auth.uid();
  assert (select array_agg(x) from public.my_re_review_ids() x) = array[review], 'Re-review not reported to the reviewer';
  update public.reviews set review_state = 'submitted', recommendation = 'accept', comments = '재심 의견', conflict_confirmed = true where id = review;
  assert (select review_state from public.reviews where id = review) = 'submitted';
  raise notice 'PASS: re-review of the revised manuscript is accepted until re_review_deadline';
end $$;
reset role;

do $$ begin
  update public.conference_settings set re_review_deadline = now() - interval '1 minute' where edition_year = 2026;
end $$;
set local role authenticated;
do $$
declare failed boolean := false;
begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'r3')::text, true);
  begin
    update public.reviews set comments = '재심 의견 수정' where paper_id = (select v from fx where k = 'paper') and reviewer_id = auth.uid();
  exception when others then failed := sqlerrm = 'Review submission is closed';
    if not failed then raise exception 'Unexpected error: %', sqlerrm; end if;
  end;
  assert failed, 'Re-review edited after re_review_deadline';
  raise notice 'PASS: re-reviews close at re_review_deadline';
end $$;
reset role;

do $$ begin
  update public.conference_settings set re_review_deadline = null, review_deadline = now() + interval '1 day' where edition_year = 2026;
end $$;
set local role authenticated;
do $$ begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'r3')::text, true);
  update public.reviews set comments = '재심 의견 수정' where paper_id = (select v from fx where k = 'paper') and reviewer_id = auth.uid();
  assert (select comments from public.reviews where paper_id = (select v from fx where k = 'paper') and reviewer_id = auth.uid()) = '재심 의견 수정';
  raise notice 'PASS: without a re-review deadline, re-reviews follow review_deadline as before';
end $$;
reset role;

set local role anon;
do $$ begin
  perform re_review_deadline from public.conference_settings where edition_year = 2026;
  raise notice 'PASS: anon can read re_review_deadline for the public portal';
end $$;
reset role;
rollback;
