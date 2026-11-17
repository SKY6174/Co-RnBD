-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-chair-announcements.sql
begin;
select pg_advisory_xact_lock(6182741301);
do $$
begin
  if exists (select 1 from auth.users where email not like '%@example.test') then
    raise exception 'Refusing to run: non-synthetic accounts present';
  end if;
end $$;

create temp table fx (k text primary key, v uuid) on commit drop;
grant select, insert on fx to authenticated, anon;

do $$
declare y int := app_private.current_edition_year();
  chair uuid := gen_random_uuid(); confirmed uuid := gen_random_uuid(); applied uuid := gen_random_uuid();
  author uuid := gen_random_uuid(); drafter uuid := gen_random_uuid(); reviewer uuid := gen_random_uuid();
  unverified uuid := gen_random_uuid(); suppressed uuid := gen_random_uuid(); member uuid := gen_random_uuid();
  p1 uuid := gen_random_uuid(); p2 uuid := gen_random_uuid(); p3 uuid := gen_random_uuid(); p4 uuid := gen_random_uuid();
  abstract text := repeat('로컬 검증용 합성 초록입니다. ', 5);
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data) values
    (chair, 'an-chair@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (confirmed, 'An-Confirmed@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (applied, 'an-applied@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (author, 'an-author@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (drafter, 'an-drafter@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (reviewer, 'an-reviewer@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (unverified, 'an-unverified@example.test', 'authenticated', 'authenticated', null, '{}'),
    (suppressed, 'an-suppressed@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (member, 'an-member@example.test', 'authenticated', 'authenticated', now(), '{}');
  update public.profiles set full_name = '합성 회원', affiliation = '로컬 검증 기관' where user_id in (chair, confirmed, applied, author, drafter, reviewer, unverified, suppressed, member);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  update app_private.review_email_config set enabled = false;
  -- Registrations: bypass the public-window guard by inserting directly as the table owner.
  alter table public.attendee_registrations disable trigger user;
  insert into public.attendee_registrations (user_id, category, attendance_days, status, edition_year) values
    (confirmed, 'faculty', array['2026-12-17'::date], 'confirmed', y),
    (applied, 'student', array['2026-12-17'::date], 'applied', y),
    (unverified, 'student', array['2026-12-17'::date], 'confirmed', y),
    (suppressed, 'student', array['2026-12-17'::date], 'confirmed', y);
  alter table public.attendee_registrations enable trigger user;
  alter table public.papers disable trigger user;
  insert into public.papers (id, owner_id, edition_year, title, abstract, track, paper_type, preferred_presentation, status, contact_name, contact_email, submitted_at) values
    (p1, author, y, '[LOCAL] 채택 원고', abstract, 'master_eng', 'research', 'oral', 'accepted', '합성', 'an-author@example.test', now()),
    (p2, author, y, '[LOCAL] 두 번째 원고', abstract, 'master_eng', 'research', 'oral', 'submitted', '합성', 'an-author@example.test', now()),
    (p3, drafter, y, '[LOCAL] 초안', abstract, 'master_eng', 'research', 'oral', 'draft', '합성', 'an-drafter@example.test', null),
    (p4, confirmed, y, '[LOCAL] 확정자 초안', abstract, 'master_eng', 'research', 'oral', 'draft', '합성', 'an-confirmed@example.test', null);
  alter table public.papers enable trigger user;
  alter table public.reviews disable trigger user;
  insert into public.reviews (paper_id, reviewer_id, review_state, manuscript_submitted_at) values (p2, reviewer, 'assigned', now());
  alter table public.reviews enable trigger user;
  -- An earlier hard bounce for one registrant
  insert into app_private.review_email_outbox (id, event_key, recipient_email, kind, payload, status) values (gen_random_uuid(), 'an:bounce', 'an-suppressed@example.test', 'decision', '{}', 'sent');
  insert into app_private.email_suppressions (email, reason, source_outbox_id) select 'an-suppressed@example.test', 'bounce', id from app_private.review_email_outbox where event_key = 'an:bounce';
  insert into fx values ('chair', chair), ('member', member), ('confirmed', confirmed), ('author', author), ('reviewer', reviewer), ('drafter', drafter), ('applied', applied);
end $$;

-- Recipient groups
do $$
declare y int := app_private.current_edition_year();
begin
  if (select count(*) from app_private.announcement_recipients('registrants_confirmed', y)) <> 1 then raise exception 'registrants_confirmed: unverified/suppressed not excluded'; end if;
  if (select email from app_private.announcement_recipients('registrants_confirmed', y)) <> 'an-confirmed@example.test' then raise exception 'email not lowercased'; end if;
  if (select count(*) from app_private.announcement_recipients('registrants_active', y)) <> 2 then raise exception 'registrants_active count'; end if;
  if (select count(*) from app_private.announcement_recipients('authors_submitted', y)) <> 1 then raise exception 'authors_submitted must dedupe owner with two papers'; end if;
  if (select count(*) from app_private.announcement_recipients('authors_accepted', y)) <> 1 then raise exception 'authors_accepted count'; end if;
  if (select array_agg(user_id) from app_private.announcement_recipients('authors_draft', y)) is distinct from array[(select v from fx where k='drafter')]
    and (select count(*) from app_private.announcement_recipients('authors_draft', y)) <> 2 then raise exception 'authors_draft unexpected'; end if;
  if (select count(*) from app_private.announcement_recipients('reviewers_active', y)) <> 1 then raise exception 'reviewers_active count'; end if;
  if (select count(*) from app_private.announcement_recipients('nonsense', y)) <> 0 then raise exception 'unknown segment returned rows'; end if;
end $$;

-- Non-chair and anon are refused
select set_config('request.jwt.claims', json_build_object('sub', (select v from fx where k='member'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  begin perform public.chair_announcement_preview('registrants_confirmed'); raise exception 'member previewed';
  exception when insufficient_privilege then null; end;
  begin perform public.chair_announcement_save(null, 'registrants_confirmed', '제목입니다', '본문 내용은 열 글자 이상입니다.'); raise exception 'member saved';
  exception when insufficient_privilege then null; end;
  begin perform 1 from app_private.announcements; raise exception 'member read table';
  exception when insufficient_privilege then null; end;
  begin perform app_private.announcement_recipients('registrants_confirmed', 2026); raise exception 'member called helper';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role anon;
do $$ begin
  begin perform public.chair_announcements(5); raise exception 'anon listed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- Chair flow
select set_config('request.jwt.claims', json_build_object('sub', (select v from fx where k='chair'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
declare id uuid; n int; addr text; r record;
begin
  if public.chair_announcement_preview('registrants_active') <> 2 then raise exception 'preview count'; end if;
  begin perform public.chair_announcement_save(null, 'registrants_active', 'x', '본문 내용은 열 글자 이상입니다.'); raise exception 'short subject accepted';
  exception when check_violation then null; end;
  begin perform public.chair_announcement_save(null, 'registrants_active', e'줄\n바꿈', '본문 내용은 열 글자 이상입니다.'); raise exception 'newline subject accepted';
  exception when check_violation then null; end;
  begin perform public.chair_announcement_save(null, 'everyone', '제목입니다', '본문 내용은 열 글자 이상입니다.'); raise exception 'bad segment accepted';
  exception when check_violation then null; end;

  id := public.chair_announcement_save(null, 'registrants_active', ' 행사장 안내 ', '행사장은 본관 2층입니다.

등록 데스크는 9시에 엽니다.');
  insert into fx values ('ann', id);
  begin perform public.chair_announcement_confirm(id, 2); raise exception 'confirmed without test';
  exception when object_not_in_prerequisite_state then null; end;

  addr := public.chair_announcement_test(id);
  if addr <> 'an-chair@example.test' then raise exception 'test went to %', addr; end if;
  -- Editing content clears the test; saving identical content keeps it
  perform public.chair_announcement_save(id, 'registrants_active', '행사장 안내', '행사장은 본관 2층입니다.

등록 데스크는 9시에 엽니다.');
  if (select test_sent_at from public.chair_announcements(5) a where a.id = (select v from fx where k='ann')) is null then raise exception 'identical save cleared test'; end if;
  perform public.chair_announcement_save(id, 'registrants_active', '행사장 안내 (수정)', '행사장은 본관 2층입니다.');
  begin perform public.chair_announcement_confirm(id, 2); raise exception 'confirmed after edit without retest';
  exception when object_not_in_prerequisite_state then null; end;
  perform public.chair_announcement_test(id);

  begin perform public.chair_announcement_confirm(id, 3); raise exception 'count mismatch accepted';
  exception when serialization_failure then null; end;
  n := public.chair_announcement_confirm(id, 2);
  if n <> 2 then raise exception 'confirm returned %', n; end if;
  begin perform public.chair_announcement_confirm(id, 2); raise exception 'double confirm';
  exception when object_not_in_prerequisite_state then null; end;
  begin perform public.chair_announcement_save(id, 'registrants_active', '수정 시도', '확정 후에는 수정할 수 없어야 합니다.'); raise exception 'edited after confirm';
  exception when object_not_in_prerequisite_state then null; end;

  select * into r from public.chair_announcements(5) a where a.id = (select v from fx where k='ann');
  if r.recipient_count <> 2 or r.pending <> 2 or r.sent <> 0 then raise exception 'list counts wrong: % % %', r.recipient_count, r.pending, r.sent; end if;
end $$;
reset role;

-- Outbox rows: payload, reply-to, one per recipient, test rows separate
do $$
declare bad int;
begin
  if (select count(*) from app_private.review_email_outbox where announcement_id = (select v from fx where k='ann') and not is_test) <> 2 then raise exception 'outbox rows'; end if;
  if (select count(*) from app_private.review_email_outbox where announcement_id = (select v from fx where k='ann') and is_test) <> 2 then raise exception 'test rows'; end if;
  select count(*) into bad from app_private.review_email_outbox
    where announcement_id = (select v from fx where k='ann')
      and not (payload->>'version' = '6' and payload->>'kind' = 'announcement' and payload->>'replyTo' = 'office@co-rnbd.org'
        and (is_test or payload->>'subject' = '행사장 안내 (수정)') and payload->>'note' = '' and payload->>'recipient' = recipient_email
        and status = 'queued' and recipient_id is not null and paper_id is null);
  if bad <> 0 then raise exception '% malformed announcement rows', bad; end if;
end $$;

-- Cancel stops queued rows and is reflected in the list
select set_config('request.jwt.claims', json_build_object('sub', (select v from fx where k='chair'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
declare n int; r record;
begin
  n := public.chair_announcement_cancel((select v from fx where k='ann'));
  if n <> 2 then raise exception 'cancel reported % (expected 2 recipients)', n; end if;
  select * into r from public.chair_announcements(5) a where a.id = (select v from fx where k='ann');
  if r.cancelled_at is null or r.pending <> 0 or r.cancelled <> 2 then raise exception 'cancel not reflected'; end if;
end $$;
reset role;
do $$ begin
  if exists(select 1 from app_private.review_email_outbox where announcement_id = (select v from fx where k='ann') and status <> 'cancelled') then raise exception 'pending test rows not cancelled'; end if;
end $$;

select 'PASS: chair announcements' as result;
rollback;
