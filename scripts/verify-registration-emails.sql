-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back,
-- including the pg_net request queue (pg_net sends only after commit).
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-registration-emails.sql
begin;
select pg_advisory_xact_lock(6182741301);
do $$
begin
  if exists (select 1 from auth.users where email not like '%@example.test') then
    raise exception 'Refusing to run: non-synthetic accounts present';
  end if;
end $$;

create temp table fx (k text primary key, v uuid) on commit drop;
grant select on fx to authenticated;

do $$
declare chair uuid := gen_random_uuid(); member uuid := gen_random_uuid(); unverified uuid := gen_random_uuid(); early uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data) values
    (chair, 're-chair@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (member, 'RE-Member@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (unverified, 're-unverified@example.test', 'authenticated', 'authenticated', null, '{}'),
    (early, 're-early@example.test', 'authenticated', 'authenticated', now(), '{}');
  update public.profiles set full_name = '홍 길동', affiliation = '로컬 검증 기관' where user_id in (chair, member, unverified, early);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  update public.conference_settings set registration_open = true, registration_deadline = now() + interval '7 days' where edition_year = 2026;
  update app_private.review_email_config set enabled = false, registration_enabled = false;
  insert into fx values ('chair', chair), ('member', member), ('unverified', unverified), ('early', early);
end $$;

-- Off by default: a registration made while disabled queues nothing.
set local role authenticated;
do $$ begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'early')::text, true);
  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days)
    values ((select v from fx where k = 'early'), 2026, 'faculty', array[date '2027-01-20']);
end $$;
reset role;
do $$ begin
  assert not exists (select 1 from app_private.review_email_outbox where recipient_id = (select v from fx where k = 'early')), 'Queued while disabled';
  raise notice 'PASS: nothing queued while registration mail is disabled';
  update app_private.review_email_config set registration_enabled = true;
end $$;

set local role authenticated;
do $$
declare reg uuid;
begin
  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'member')::text, true);
  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days)
    values ((select v from fx where k = 'member'), 2026, 'student', array[date '2027-01-20', date '2027-01-21']) returning id into reg;
  update public.attendee_registrations set category = 'faculty' where id = reg;  -- not a status change
  update public.attendee_registrations set status = 'cancelled' where id = reg;
  update public.attendee_registrations set status = 'applied' where id = reg;   -- re-apply

  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'unverified')::text, true);
  insert into public.attendee_registrations (user_id, edition_year, category, attendance_days)
    values ((select v from fx where k = 'unverified'), 2026, 'other', array[date '2027-01-21']);

  perform set_config('request.jwt.claim.sub', (select v from fx where k = 'chair')::text, true);
  update public.attendee_registrations set status = 'confirmed' where id = reg;
end $$;
reset role;

do $$
declare member uuid := (select v from fx where k = 'member'); kinds text[]; p jsonb;
begin
  select array_agg(kind order by substring(event_key from '[0-9]{4}-[0-9]{2}-[0-9]{2}T.*$')) into kinds from app_private.review_email_outbox where recipient_id = member;
  assert kinds = array['registration_received', 'registration_cancelled', 'registration_received', 'registration_confirmed'],
    'Unexpected mail sequence: ' || kinds::text;
  raise notice 'PASS: received, cancelled, re-applied and confirmed each queue one mail; a category change queues none';

  select payload into p from app_private.review_email_outbox where recipient_id = member and kind = 'registration_confirmed';
  assert p ->> 'version' = '5' and p ->> 'recipient' = 're-member@example.test' and p ->> 'registrationStatus' = 'confirmed'
    and p ->> 'category' = 'faculty' and p -> 'attendanceDays' = '["2027-01-20", "2027-01-21"]'::jsonb and p ->> 'recipientName' = '홍 길동',
    'Payload wrong: ' || p::text;
  assert not (p ? 'paperId'), 'Registration mail carries paper fields';
  raise notice 'PASS: payload has the verified lower-case address, state, category and days only';

  assert (select status = 'failed' and last_error = 'recipient_unverified' from app_private.review_email_outbox
    where recipient_id = (select v from fx where k = 'unverified')), 'Unverified address was queued';
  raise notice 'PASS: an unverified email address is never queued for sending';
end $$;

-- Send-time check: only the current state's mail goes out; superseded ones are cancelled.
do $$
declare member uuid := (select v from fx where k = 'member');
begin
  perform vault.create_secret(repeat('x', 40), 'review_email_webhook_token');
exception when unique_violation then null;
end $$;
do $$
declare member uuid := (select v from fx where k = 'member');
begin
  update app_private.review_email_outbox set status = 'queued', next_attempt_at = now() - interval '1 minute' where recipient_id = member;
  update app_private.review_email_config set enabled = true;
  for i in 1..3 loop perform app_private.process_review_email_queue(); end loop;
  assert (select count(*) from app_private.review_email_outbox where recipient_id = member and status = 'cancelled' and last_error = 'registration_obsolete') = 3,
    'Superseded mails not cancelled';
  assert (select status from app_private.review_email_outbox where recipient_id = member and kind = 'registration_confirmed') = 'sending',
    'Current confirmation not dispatched';
  raise notice 'PASS: only the current confirmation is dispatched; superseded mails are cancelled';

  update app_private.review_email_config set registration_enabled = false;
  update app_private.review_email_outbox set status = 'queued', request_id = null where recipient_id = member and kind = 'registration_confirmed';
  perform app_private.process_review_email_queue();
  assert (select status from app_private.review_email_outbox where recipient_id = member and kind = 'registration_confirmed') = 'queued',
    'Dispatched while registration mail disabled';
  raise notice 'PASS: turning the flag off holds registration mail without affecting the rest';
end $$;
rollback;
