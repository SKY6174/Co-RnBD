-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-marketing-consent.sql
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
declare chair uuid := gen_random_uuid(); fan uuid := gen_random_uuid(); old_fan uuid := gen_random_uuid();
  quitter uuid := gen_random_uuid(); unverified uuid := gen_random_uuid(); bounced uuid := gen_random_uuid(); other uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data) values
    (chair, 'mc-chair@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (fan, 'MC-Fan@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (old_fan, 'mc-old@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (quitter, 'mc-quit@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (unverified, 'mc-unverified@example.test', 'authenticated', 'authenticated', null, '{}'),
    (bounced, 'mc-bounced@example.test', 'authenticated', 'authenticated', now(), '{}'),
    (other, 'mc-other@example.test', 'authenticated', 'authenticated', now(), '{}');
  update public.profiles set full_name = '합성 회원', affiliation = '로컬' where user_id in (chair, fan, old_fan, quitter, unverified, bounced, other);
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  update app_private.review_email_config set enabled = false;
  insert into fx values ('chair', chair), ('fan', fan), ('old', old_fan), ('quit', quitter), ('unverified', unverified), ('bounced', bounced), ('other', other);
end $$;

create or replace function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from fx where fx.k = $1), 'role', 'authenticated')::text, true);
$$;

-- Consent changes through the member RPC
select pg_temp.as_user('fan');
set local role authenticated;
do $$
begin
  begin perform public.set_marketing_consent(true, 'unsubscribe_link'); raise exception 'member used link source';
  exception when invalid_parameter_value then null; end;
  if public.set_marketing_consent(false, 'mypage') <> 'unchanged' then raise exception 'withdraw without consent changed state'; end if;
  if public.set_marketing_consent(true, 'registration') <> 'granted' then raise exception 'grant failed'; end if;
  if public.set_marketing_consent(true, 'mypage') <> 'unchanged' then raise exception 'repeat grant changed state'; end if;
  -- Own row is visible without the token; direct writes are refused
  if not (select consented from public.marketing_consents where user_id = (select v from fx where k='fan')) then raise exception 'own row not visible'; end if;
  begin perform unsubscribe_token from public.marketing_consents; raise exception 'token column readable';
  exception when insufficient_privilege then null; end;
  begin update public.marketing_consents set consented = false; raise exception 'direct update allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

select pg_temp.as_user('other');
set local role authenticated;
do $$ begin
  if exists (select 1 from public.marketing_consents) then raise exception 'other member sees consent rows'; end if;
end $$;
reset role;

select pg_temp.as_user('unverified');
set local role authenticated;
do $$ begin
  begin perform public.set_marketing_consent(true, 'mypage'); raise exception 'unverified granted';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

set local role anon;
do $$ begin
  begin perform public.set_marketing_consent(true, 'mypage'); raise exception 'anon granted';
  exception when insufficient_privilege then null; end;
  if public.unsubscribe_marketing(gen_random_uuid()) <> 'unknown' then raise exception 'unknown token accepted'; end if;
end $$;
reset role;

-- Other consenting members (as table owner, through the shared helper)
do $$ begin
  perform app_private.apply_marketing_consent((select v from fx where k='old'), true, 'mypage');
  update public.marketing_consents set consented_at = now() - interval '2 years 1 day' where user_id = (select v from fx where k='old');
  perform app_private.apply_marketing_consent((select v from fx where k='quit'), true, 'mypage');
  perform app_private.apply_marketing_consent((select v from fx where k='bounced'), true, 'mypage');
  insert into app_private.review_email_outbox (id, event_key, recipient_email, kind, payload, status) values (gen_random_uuid(), 'mc:bounce', 'mc-bounced@example.test', 'decision', '{}', 'sent');
  insert into app_private.email_suppressions (email, reason, source_outbox_id) select 'mc-bounced@example.test', 'bounce', id from app_private.review_email_outbox where event_key = 'mc:bounce';
end $$;

-- History and processing notices
do $$
declare n int;
begin
  select count(*) into n from app_private.marketing_consent_events where user_id = (select v from fx where k='fan');
  if n <> 1 then raise exception 'fan history rows %', n; end if;
  if (select source from app_private.marketing_consent_events where user_id = (select v from fx where k='fan')) <> 'registration' then raise exception 'source not recorded'; end if;
  select count(*) into n from app_private.review_email_outbox where kind = 'consent_notice' and recipient_id = (select v from fx where k='fan');
  if n <> 1 then raise exception 'fan notices %', n; end if;
  if (select concat(payload->>'version', payload->>'action', payload->>'replyTo') from app_private.review_email_outbox where kind = 'consent_notice' and recipient_id = (select v from fx where k='fan'))
    <> '7grantedoffice@co-rnbd.org' then raise exception 'notice payload wrong'; end if;
end $$;

-- Promotional segment: active consent within two years, verified, not suppressed
do $$
declare got uuid[];
begin
  select array_agg(user_id order by user_id) into got from app_private.announcement_recipients('marketing_consented', app_private.current_edition_year());
  if got is distinct from (select array_agg(v order by v) from fx where k in ('fan','quit')) then raise exception 'promotional segment wrong: %', got; end if;
end $$;

-- Chair: promotional test without own consent, then confirm under the time rule
select pg_temp.as_user('chair');
set local role authenticated;
do $$
declare id uuid; local timestamp := now() at time zone 'Asia/Seoul'; allowed boolean; n int;
begin
  id := public.chair_announcement_save(null, 'marketing_consented', '차기 학회 안내', '내년 학회 일정과 주제를 미리 알려 드립니다.');
  insert into fx values ('ad', id);
  perform public.chair_announcement_test(id);
  allowed := local::time >= time '08:00' and (local + interval '31 minutes')::date = local::date and (local + interval '31 minutes')::time <= time '21:00';
  begin
    n := public.chair_announcement_confirm(id, 2);
    if not allowed then raise exception 'promotional confirm allowed at night'; end if;
    if n <> 2 then raise exception 'promo confirm count %', n; end if;
  exception when object_not_in_prerequisite_state then
    if allowed then raise exception 'promotional confirm refused in daytime'; end if;
    raise notice 'Night-time run: confirm correctly refused; payload checks use the test row only';
  end;
end $$;
reset role;

do $$
declare test_payload jsonb; bad int;
begin
  select payload into test_payload from app_private.review_email_outbox where announcement_id = (select v from fx where k='ad') and is_test;
  if test_payload->>'promotional' <> 'true' or test_payload ? 'unsubscribeToken' or test_payload ? 'consentedAt' then raise exception 'chair test payload wrong: %', test_payload; end if;
  select count(*) into bad from app_private.review_email_outbox o
    join public.marketing_consents c on c.user_id = o.recipient_id
    where o.announcement_id = (select v from fx where k='ad') and not o.is_test
      and not (o.payload->>'promotional' = 'true' and o.payload->>'unsubscribeToken' = c.unsubscribe_token::text and o.payload ? 'consentedAt');
  if bad <> 0 then raise exception '% promo rows missing consent fields', bad; end if;
  -- Non-promotional announcements never carry promotional fields
  if exists (select 1 from app_private.review_email_outbox where kind = 'announcement' and announcement_id <> (select v from fx where k='ad') and payload ? 'promotional') then raise exception 'non-promo carries promo fields'; end if;
end $$;

-- Unsubscribe link withdraws, cancels pending promotional mail, notifies, and is idempotent
set local role anon;
do $$
declare tok uuid;
begin
  select unsubscribe_token into tok from public.marketing_consents where user_id = (select v from fx where k='quit');
  raise exception 'anon read token';
exception when insufficient_privilege then null;
end $$;
reset role;
do $$
declare tok uuid; r text; queued_before int;
begin
  select unsubscribe_token into tok from public.marketing_consents where user_id = (select v from fx where k='quit');
  select count(*) into queued_before from app_private.review_email_outbox where recipient_id = (select v from fx where k='quit') and payload->>'promotional' = 'true' and status = 'queued';
  set local role anon;
  r := public.unsubscribe_marketing(tok);
  reset role;
  if r <> 'withdrawn' then raise exception 'unsubscribe returned %', r; end if;
  if public.unsubscribe_marketing(tok) <> 'already' then raise exception 'second unsubscribe not idempotent'; end if;
  if exists (select 1 from app_private.review_email_outbox where recipient_id = (select v from fx where k='quit') and payload->>'promotional' = 'true' and status = 'queued') then raise exception 'promo mail still queued after unsubscribe'; end if;
  if queued_before > 0 and not exists (select 1 from app_private.review_email_outbox where recipient_id = (select v from fx where k='quit') and last_error = 'consent_withdrawn') then raise exception 'cancel reason missing'; end if;
  if (select count(*) from app_private.marketing_consent_events where user_id = (select v from fx where k='quit') and action = 'withdrawn' and source = 'unsubscribe_link') <> 1 then raise exception 'withdraw history missing'; end if;
  if (select count(*) from app_private.review_email_outbox where kind = 'consent_notice' and recipient_id = (select v from fx where k='quit') and payload->>'action' = 'withdrawn') <> 1 then raise exception 'withdraw notice missing'; end if;
  if exists (select 1 from app_private.announcement_recipients('marketing_consented', app_private.current_edition_year()) where user_id = (select v from fx where k='quit')) then raise exception 'withdrawn member still targeted'; end if;
  -- Re-consent from mypage restarts the two-year window
  perform app_private.apply_marketing_consent((select v from fx where k='old'), false, 'mypage');
  perform app_private.apply_marketing_consent((select v from fx where k='old'), true, 'mypage');
  if not exists (select 1 from app_private.announcement_recipients('marketing_consented', app_private.current_edition_year()) where user_id = (select v from fx where k='old')) then raise exception 're-consent not targeted'; end if;
end $$;

select 'PASS: marketing consent' as result;
rollback;
