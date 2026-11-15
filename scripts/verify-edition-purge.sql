-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-edition-purge.sql
begin;
do $$
begin
  if exists (select 1 from auth.users where email not like '%@example.test') then
    raise exception 'Refusing to run: non-synthetic accounts present';
  end if;
end $$;

create temp table fx (k text primary key, v uuid) on commit drop;

do $$
declare
  chair uuid := gen_random_uuid(); a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid(); a3 uuid := gen_random_uuid();
  r1 uuid := gen_random_uuid(); r2 uuid := gen_random_uuid(); cm uuid := gen_random_uuid();
  recent uuid := gen_random_uuid(); nextreg uuid := gen_random_uuid();
  p1 uuid := gen_random_uuid(); p2 uuid := gen_random_uuid(); p3 uuid := gen_random_uuid();
  u uuid; p uuid; path text; s_pub uuid; s_draft uuid; sp_pub uuid; sp_draft uuid; reg uuid;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data, created_at, last_sign_in_at)
  select id, email, 'authenticated', 'authenticated', now() - interval '10 days', '{}', now() - interval '10 days', now() - interval '10 days'
  from (values (chair,'ep-chair@example.test'),(a1,'ep-a1@example.test'),(a2,'ep-a2@example.test'),(a3,'ep-a3@example.test'),
               (r1,'ep-r1@example.test'),(r2,'ep-r2@example.test'),(cm,'ep-committee@example.test'),
               (recent,'ep-recent@example.test'),(nextreg,'ep-nextreg@example.test')) v(id, email);
  update public.profiles set full_name = '합성 ' || split_part(email, '@', 1), affiliation = '로컬 검증 기관'
    where user_id in (chair, a1, a2, a3, r1, r2, cm, recent, nextreg);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  update public.conference_settings set submissions_open = true, submission_deadline = null,
    final_uploads_open = true, final_deadline = null, registration_open = true, registration_deadline = now() + interval '30 days'
    where edition_year = 2026;

  foreach p in array array[p1, p2, p3] loop
    u := case p when p1 then a1 when p2 then a2 else a3 end;
    perform set_config('request.jwt.claim.sub', u::text, true);
    insert into public.papers (id, owner_id, title, abstract, track, paper_type, preferred_presentation, edition_year, contact_name, contact_email)
      values (p, u, 'LOCAL PURGE FIXTURE ' || left(p::text, 4), 'Synthetic purge fixture only.', 'master_eng', 'research', 'oral', 2026, 'Author',
        (select email from auth.users where id = u));
    insert into public.paper_authors (paper_id, sort_order, full_name, affiliation, email) values
      (p, 1, '대표 저자 ' || left(p::text, 4), '로컬 대학', (select email from auth.users where id = u)),
      (p, 2, '공동 저자 ' || left(p::text, 4), '로컬 기업', 'ep-coauthor@example.test');
    path := u::text || '/' || p::text || '/submission.pdf';
    insert into storage.objects (bucket_id, name, owner_id, metadata) values ('paper-pdfs', path, u::text, '{"mimetype":"application/pdf","size":100}');
    insert into public.paper_files (paper_id, storage_path, original_name, version, uploaded_by, file_stage) values (p, path, 'submission.pdf', 1, u, 'submission');
    update public.papers set status = 'submitted' where id = p;
    perform set_config('request.jwt.claim.sub', chair::text, true);
    perform public.chair_assign_reviewer(p, r1, null, '');
    perform public.chair_assign_reviewer(p, r2, null, '');
    update public.papers set status = case when p = p3 then 'rejected' else 'accepted' end,
      decision_note = '로컬 검증 판정', decision_exception_reason = '로컬 검증 예외 판정' where id = p;
  end loop;

  -- p1: final + consent (kept); p2: final, no consent (deleted); p3: rejected (deleted)
  foreach p in array array[p1, p2] loop
    u := case p when p1 then a1 else a2 end;
    perform set_config('request.jwt.claim.sub', u::text, true);
    path := u::text || '/' || p::text || '/final.pdf';
    insert into storage.objects (bucket_id, name, owner_id, metadata) values ('paper-pdfs', path, u::text, '{"mimetype":"application/pdf","size":100}');
    insert into public.paper_files (paper_id, storage_path, original_name, version, uploaded_by, file_stage) values (p, path, 'final.pdf', 2, u, 'final');
  end loop;
  perform set_config('request.jwt.claim.sub', a1::text, true);
  insert into public.paper_publication_consents (paper_id, consented, coauthors_confirmed) values (p1, true, true);
  perform set_config('request.jwt.claim.sub', a2::text, true);
  insert into public.paper_publication_consents (paper_id, consented, coauthors_confirmed) values (p2, false, false);
  -- orphan upload from a paper deleted earlier
  insert into storage.objects (bucket_id, name, owner_id, metadata)
    values ('paper-pdfs', a3::text || '/' || gen_random_uuid()::text || '/orphan.pdf', a3::text, '{"mimetype":"application/pdf","size":100}');

  perform set_config('request.jwt.claim.sub', chair::text, true);
  insert into app_private.review_email_outbox (event_key, paper_id, recipient_id, recipient_email, kind, payload)
    values ('local-purge-' || p1, p1, r1, 'ep-r1@example.test', 'reviewer_assignment', '{}');
  insert into public.review_committee (edition_year, track, committee_role, email, display_name)
    values (2026, 'master_eng', 'reviewer', 'ep-committee@example.test', '합성 위원');
  insert into public.program_speakers (edition_year, full_name, affiliation, is_published) values
    (2026, '공개 연사', '공개 기관', true), (2026, '비공개 연사', '비공개 기관', false);
  insert into public.program_sessions (edition_year, title, session_type, starts_at, ends_at, room, is_published) values
    (2026, '공개 세션', 'oral', '2027-01-20 10:00+09', '2027-01-20 11:00+09', '로컬 강의실', true),
    (2026, '비공개 세션', 'oral', null, null, '', false);
  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days, status)
    values (a3, 2026, 'faculty', array[date '2027-01-20'], 'confirmed');

  insert into fx values ('chair', chair), ('a1', a1), ('a2', a2), ('a3', a3), ('r1', r1), ('r2', r2), ('cm', cm),
    ('recent', recent), ('nextreg', nextreg), ('p1', p1), ('p2', p2), ('p3', p3);
  raise notice 'PASS: synthetic edition with accepted/consented, accepted/refused and rejected papers';
end $$;

do $$
declare failed boolean; chair uuid := (select v from fx where k = 'chair'); result jsonb; preview jsonb;
begin
  perform set_config('request.jwt.claim.sub', chair::text, true);
  failed := false;
  begin perform app_private.purge_edition_personal_data(2026, 'PURGE EDITION 2026');
  exception when others then failed := sqlerrm like '%after the conference ends%'; end;
  assert failed, 'Purge allowed before the event ended';

  update public.conference_editions set start_date = current_date - 10, end_date = current_date - 9 where year = 2026;
  insert into public.conference_editions (year, title, start_date, end_date, status)
    values (2099, 'Synthetic next edition 2099', date '2099-01-20', date '2099-01-21', 'draft');
  perform public.activate_conference_edition(2099);
  insert into public.conference_settings (edition_year, submissions_open, reviews_open, final_uploads_open, registration_open, registration_deadline)
    values (2099, false, false, false, true, now() + interval '1 day');
  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days, status)
    values ((select v from fx where k = 'nextreg'), 2099, 'faculty', array[date '2099-01-20'], 'applied');
  update auth.users set last_sign_in_at = now() where id = (select v from fx where k = 'recent');

  failed := false;
  begin perform app_private.purge_edition_personal_data(2026, 'PURGE EDITION 2026');
  exception when others then failed := sqlerrm like 'Run app_private.archive_and_purge_registrations%'; end;
  assert failed, 'Purge allowed while registrations remain';
  failed := false;
  begin perform app_private.purge_edition_personal_data(2026, 'purge');
  exception when others then failed := sqlerrm like 'Confirmation text%'; end;
  assert failed, 'Wrong confirmation accepted';
  failed := false;
  begin delete from public.papers where id = (select v from fx where k = 'p3');
  exception when others then failed := sqlerrm like '%Only the current conference%'; end;
  assert failed, 'Ordinary delete of an archived paper must stay blocked';
  raise notice 'PASS: refused before event end, with registrations left, with wrong confirmation; guards intact';

  perform app_private.archive_and_purge_registrations(2026, (current_date + interval '6 years')::date, 'PURGE REGISTRATIONS 2026');
  preview := app_private.preview_edition_purge(2026);
  assert (preview ->> 'papers_to_delete')::int = 3, preview::text;
  assert (preview ->> 'papers_kept_for_proceedings')::int = 1, preview::text;
  assert (preview ->> 'accepted_without_consent')::int = 1, preview::text;
  assert (preview ->> 'unpublished_speakers_to_delete')::int = 1, preview::text;
  assert (preview ->> 'unpublished_sessions_to_delete')::int = 1, preview::text;
  raise notice 'PASS: preview %', preview;

  result := app_private.purge_edition_personal_data(2026, 'PURGE EDITION 2026');
  raise notice 'PASS: purge result %', result;
  assert (result ->> 'papers_kept_for_proceedings')::int = 1 and (result ->> 'papers_deleted')::int = 3, result::text;
  assert (result ->> 'email_outbox_deleted')::int >= 1 and (result ->> 'committee_rows_deleted')::int = 1, result::text;
end $$;

do $$
declare a jsonb;
begin
  assert not exists (select 1 from public.papers where edition_year = 2026);
  assert not exists (select 1 from public.reviews r where r.paper_id in (select v from fx where k in ('p1','p2','p3')));
  assert not exists (select 1 from public.paper_authors where paper_id in (select v from fx where k in ('p1','p2','p3')));
  assert not exists (select 1 from app_private.review_email_outbox where recipient_email like 'ep-%');
  assert not exists (select 1 from public.review_committee where edition_year = 2026);
  assert not exists (select 1 from app_private.edition_purge_context);
  raise notice 'PASS: papers, authors, reviews, outbox, committee rows and purge context removed';

  select authors into a from app_private.proceedings_archive where source_paper_id = (select v from fx where k = 'p1');
  assert a is not null and jsonb_array_length(a) = 2 and a -> 0 ->> 'name' like '대표 저자%' and a -> 1 ->> 'affiliation' = '로컬 기업', coalesce(a::text, 'null');
  assert not (a::text like '%@%'), 'Proceedings archive must not keep emails';
  assert (select final_file_path from app_private.proceedings_archive where source_paper_id = (select v from fx where k = 'p1')) like '%/final.pdf';
  assert not exists (select 1 from app_private.proceedings_archive where source_paper_id in (select v from fx where k in ('p2','p3')));
  raise notice 'PASS: only the consented paper is archived, with names/affiliations and final PDF path, no emails';

  assert (select count(*) from public.program_speakers where edition_year = 2026) = 1
    and exists (select 1 from public.program_speakers where edition_year = 2026 and is_published);
  assert (select count(*) from public.program_sessions where edition_year = 2026) = 1
    and exists (select 1 from public.program_sessions where edition_year = 2026 and is_published);
  raise notice 'PASS: published speakers/sessions kept, unpublished removed';

  assert not exists (select 1 from auth.users where id in (select v from fx where k in ('a1','a2','a3','r1','r2','cm')));
  assert not exists (select 1 from public.profiles where user_id in (select v from fx where k in ('a1','a2','a3','r1','r2','cm')));
  assert exists (select 1 from auth.users where id = (select v from fx where k = 'chair'));
  assert exists (select 1 from auth.users where id = (select v from fx where k = 'recent'));
  assert exists (select 1 from auth.users where id = (select v from fx where k = 'nextreg'));
  assert exists (select 1 from public.attendee_registrations where user_id = (select v from fx where k = 'nextreg') and edition_year = 2099);
  raise notice 'PASS: member and reviewer accounts deleted; staff, recently active and next-edition accounts kept';

  assert (select count(*) from app_private.paper_pdf_paths_to_purge()) = 5, (select string_agg(path, ', ') from app_private.paper_pdf_paths_to_purge());
  assert not exists (select 1 from app_private.paper_pdf_paths_to_purge() where path like '%' || (select v from fx where k = 'p1') || '/final.pdf');
  assert exists (select 1 from app_private.paper_pdf_paths_to_purge() where path like '%' || (select v from fx where k = 'p1') || '/submission.pdf');
  raise notice 'PASS: PDF purge list = 3 submission PDFs + refused final + orphan; consented final kept';
end $$;

set local role authenticated;
do $$
declare failed boolean := false;
begin
  begin perform 1 from app_private.proceedings_archive; exception when insufficient_privilege then failed := true; end;
  assert failed, 'authenticated must not read the proceedings archive';
  failed := false;
  begin perform app_private.purge_edition_personal_data(2026, 'PURGE EDITION 2026'); exception when insufficient_privilege then failed := true; end;
  assert failed, 'authenticated must not run the purge';
  failed := false;
  begin perform * from app_private.paper_pdf_paths_to_purge(); exception when insufficient_privilege then failed := true; end;
  assert failed, 'authenticated must not list purge paths';
  raise notice 'PASS: authenticated denied on archive and purge functions';
end $$;
reset role;
rollback;
