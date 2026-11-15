-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-publication-consent.sql
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
  rev1 uuid := gen_random_uuid(); rev2 uuid := gen_random_uuid(); paper uuid := gen_random_uuid(); path text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data) values
    (chair, 'pc-chair@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (author, 'pc-author@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (other, 'pc-other@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (rev1, 'pc-rev1@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (rev2, 'pc-rev2@example.test', 'authenticated', 'authenticated', now(), '{}');
  update public.profiles set full_name = '합성 사용자', affiliation = '로컬 검증 기관' where user_id in (chair, author, other, rev1, rev2);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  update public.conference_settings set submissions_open = true, submission_deadline = null where edition_year = 2026;
  perform set_config('request.jwt.claim.sub', author::text, true);
  insert into public.papers (id, owner_id, title, abstract, track, paper_type, preferred_presentation, edition_year, contact_name, contact_email)
    values (paper, author, 'LOCAL PUBLICATION CONSENT FIXTURE', 'Synthetic publication consent fixture only.', 'master_eng', 'research', 'oral', 2026, 'Author', 'pc-author@example.test');
  insert into public.paper_authors (paper_id, sort_order, full_name, affiliation, email) values (paper, 1, 'Author', 'Local', 'pc-author@example.test');
  path := author::text || '/' || paper::text || '/submission/fixture.pdf';
  insert into storage.objects (bucket_id, name, owner_id, metadata) values ('paper-pdfs', path, author::text, '{"mimetype":"application/pdf","size":100}');
  insert into public.paper_files (paper_id, storage_path, original_name, version, uploaded_by, file_stage) values (paper, path, 'fixture.pdf', 1, author, 'submission');
  update public.papers set status = 'submitted' where id = paper;
  perform set_config('request.jwt.claim.sub', chair::text, true);
  perform public.chair_assign_reviewer(paper, rev1, null, '');
  perform public.chair_assign_reviewer(paper, rev2, null, '');
  insert into fx values ('chair', chair), ('author', author), ('other', other), ('paper', paper);
  raise notice 'PASS: synthetic paper under review';
end $$;

-- Before acceptance the author cannot record consent.
set local role authenticated;
do $$
declare failed boolean := false;
begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'author')::text, true);
  begin insert into public.paper_publication_consents (paper_id, consented, coauthors_confirmed) values ((select v from fx where k = 'paper'), true, true);
  exception when insufficient_privilege then failed := true; end;
  assert failed, 'Consent recorded before acceptance';
  raise notice 'PASS: consent refused before acceptance';
end $$;
reset role;

do $$ begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'chair')::text, true);
  update public.papers set status = 'accepted', decision_note = '로컬 검증 채택', decision_exception_reason = '로컬 검증 예외 판정' where id = (select v from fx where k = 'paper');
end $$;

set local role authenticated;
do $$
declare failed boolean; paper uuid := (select v from fx where k = 'paper'); author uuid := (select v from fx where k = 'author');
begin
  perform set_config('request.jwt.claim.sub', author::text, true);
  failed := false;
  begin insert into public.paper_publication_consents (paper_id, consented, coauthors_confirmed) values (paper, true, false);
  exception when check_violation then failed := true; end;
  assert failed, 'Consent without co-author confirmation accepted';
  raise notice 'PASS: consent requires co-author confirmation';

  insert into public.paper_publication_consents (paper_id, consented, coauthors_confirmed, decided_by, decided_at)
    values (paper, true, true, (select v from fx where k = 'other'), '2000-01-01');
  assert (select decided_by from public.paper_publication_consents where paper_id = paper) = author, 'decided_by was not stamped by the server';
  assert (select decided_at from public.paper_publication_consents where paper_id = paper) > '2020-01-01', 'decided_at was not stamped';
  raise notice 'PASS: owner records consent; server stamps who and when';

  insert into public.paper_publication_consents (paper_id, consented, coauthors_confirmed) values (paper, false, false)
    on conflict (paper_id) do update set consented = excluded.consented, coauthors_confirmed = excluded.coauthors_confirmed;
  assert (select consented from public.paper_publication_consents where paper_id = paper) = false;
  raise notice 'PASS: owner can change to refusal (upsert)';

  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'other')::text, true);
  assert not exists (select 1 from public.paper_publication_consents where paper_id = paper), 'Other user can read consent';
  update public.paper_publication_consents set consented = true, coauthors_confirmed = true where paper_id = paper;
  failed := false;
  begin insert into public.paper_publication_consents (paper_id, consented, coauthors_confirmed) values (paper, true, true);
  exception when insufficient_privilege or unique_violation then failed := true; end;
  assert failed, 'Other user wrote consent';
  raise notice 'PASS: other members can neither read nor write the consent';

  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'chair')::text, true);
  assert (select consented from public.paper_publication_consents where paper_id = paper) = false, 'Chair cannot read consent or it was altered';
  raise notice 'PASS: chair reads the unaltered consent';
end $$;
reset role;

set local role anon;
do $$
declare failed boolean := false;
begin
  begin perform 1 from public.paper_publication_consents; exception when insufficient_privilege then failed := true; end;
  assert failed, 'anon can read consents';
  raise notice 'PASS: anon denied';
end $$;
reset role;
rollback;
