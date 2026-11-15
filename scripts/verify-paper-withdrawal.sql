-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-paper-withdrawal.sql
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
declare chair uuid := gen_random_uuid(); author uuid := gen_random_uuid(); other uuid := gen_random_uuid();
  r1 uuid := gen_random_uuid(); r2 uuid := gen_random_uuid(); p uuid := gen_random_uuid(); d uuid := gen_random_uuid(); path text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data)
  select id, email, 'authenticated', 'authenticated', now(), '{}' from (values
    (chair,'wd-chair@example.test'),(author,'wd-author@example.test'),(other,'wd-other@example.test'),
    (r1,'wd-r1@example.test'),(r2,'wd-r2@example.test')) v(id,email);
  update public.profiles set full_name = '합성 사용자', affiliation = '로컬 검증 기관' where user_id in (chair, author, other, r1, r2);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  update public.conference_settings set submissions_open = true, submission_deadline = null, reviews_open = true, review_deadline = null where edition_year = 2026;
  perform set_config('request.jwt.claim.sub', author::text, true);
  insert into public.papers (id, owner_id, title, abstract, track, paper_type, preferred_presentation, edition_year, contact_name, contact_email) values
    (p, author, 'LOCAL WITHDRAWAL FIXTURE', 'Synthetic withdrawal fixture only.', 'master_eng', 'research', 'oral', 2026, 'Author', 'wd-author@example.test'),
    (d, author, 'LOCAL DRAFT FIXTURE', 'Synthetic draft fixture only.', 'master_eng', 'research', 'oral', 2026, 'Author', 'wd-author@example.test');
  insert into public.paper_authors (paper_id, sort_order, full_name, affiliation, email) values (p, 1, 'Author', 'Local', 'wd-author@example.test');
  path := author::text || '/' || p::text || '/fixture.pdf';
  insert into storage.objects (bucket_id, name, owner_id, metadata) values ('paper-pdfs', path, author::text, '{"mimetype":"application/pdf","size":100}');
  insert into public.paper_files (paper_id, storage_path, original_name, version, uploaded_by, file_stage) values (p, path, 'fixture.pdf', 1, author, 'submission');
  update public.papers set status = 'submitted' where id = p;
  perform set_config('request.jwt.claim.sub', chair::text, true);
  perform public.chair_assign_reviewer(p, r1, null, '');
  perform public.chair_assign_reviewer(p, r2, null, '');
  insert into app_private.review_email_outbox (event_key, paper_id, recipient_id, recipient_email, kind, payload, status)
    values ('local-withdraw-' || p, p, r1, 'wd-r1@example.test', 'reviewer_assignment', '{}', 'queued');
  insert into fx values ('chair', chair), ('author', author), ('other', other), ('r1', r1), ('p', p), ('d', d);
  raise notice 'PASS: synthetic paper under review with two reviewers and a queued email';
end $$;

set local role authenticated;
do $$
declare failed boolean; p uuid := (select v from fx where k = 'p');
begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'other')::text, true);
  failed := false;
  begin perform public.withdraw_paper(p, '타인'); exception when others then failed := sqlerrm like 'Only the author%'; end;
  assert failed, 'Another member withdrew the paper';

  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'author')::text, true);
  failed := false;
  begin perform public.withdraw_paper((select v from fx where k = 'd'), ''); exception when others then failed := sqlerrm like '%cannot be withdrawn%'; end;
  assert failed, 'A draft was withdrawn';
  update public.papers set status = 'withdrawn' where id = p;
  assert (select status from public.papers where id = p) = 'under_review', 'Direct status update bypassed the RPC';
  raise notice 'PASS: other members, drafts and direct updates cannot withdraw';

  perform public.withdraw_paper(p, '  다른 학회에 게재 예정  ');
  assert (select status from public.papers where id = p) = 'withdrawn';
  assert (select withdrawal_reason from public.papers where id = p) = '다른 학회에 게재 예정';
  assert (select withdrawn_at from public.papers where id = p) is not null;
  raise notice 'PASS: author withdrew; reason trimmed and time recorded';

  failed := false;
  begin perform public.withdraw_paper(p, ''); exception when others then failed := sqlerrm like '%cannot be withdrawn%'; end;
  assert failed, 'Withdrawn paper withdrawn twice';

  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'r1')::text, true);
  failed := false;
  begin update public.reviews set review_state = 'submitted', recommendation = 'accept', comments = '의견', conflict_confirmed = true
    where paper_id = p and reviewer_id = (select v from fx where k = 'r1');
  exception when others then failed := true; end;
  assert failed or not exists (select 1 from public.reviews where paper_id = p and review_state = 'submitted'), 'Review submitted for a withdrawn paper';
  raise notice 'PASS: reviewers can no longer submit for the withdrawn paper';
end $$;
reset role;

do $$
declare p uuid := (select v from fx where k = 'p');
begin
  assert (select status from app_private.review_email_outbox where event_key = 'local-withdraw-' || p) = 'cancelled', 'Queued email not cancelled';
  assert exists (select 1 from public.paper_events where paper_id = p and after_data ->> 'status' = 'withdrawn'), 'Withdrawal not in paper history';
  raise notice 'PASS: queued email cancelled; withdrawal recorded in the chair history';

  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'chair')::text, true);
  update public.papers set status = 'under_review' where id = p;
  assert (select status from public.papers where id = p) = 'under_review';
  raise notice 'PASS: chair can restore an accidental withdrawal';
end $$;
rollback;
