-- LOCAL disposable database only. Synthetic @example.test rows; everything rolls back.
-- docker exec -i <local db container> psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q < scripts/verify-email-delivery-feedback.sql
begin;
select pg_advisory_xact_lock(6182741301);
do $$
begin
  if exists (select 1 from auth.users where email not like '%@example.test') then
    raise exception 'Refusing to run: non-synthetic accounts present';
  end if;
end $$;

create temp table fx (k text primary key, v uuid) on commit drop;
grant select on fx to authenticated, anon;
select vault.create_secret(repeat('t', 40), 'review_email_webhook_token');

do $$
declare chair uuid := gen_random_uuid(); paper uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, raw_user_meta_data)
  values (chair, 'fb-chair@example.test', 'authenticated', 'authenticated', now(), '{}');
  insert into public.staff_roles (user_id, role) values (chair, 'chair');
  insert into public.papers (id, owner_id, edition_year, title, abstract, track, paper_type, preferred_presentation, status, contact_name, contact_email)
  values (paper, chair, app_private.current_edition_year(), '[LOCAL] 전달 결과 검증', repeat('로컬 검증용 합성 원고입니다. ', 20), 'master_eng', 'research', 'oral', 'draft', '합성', 'fb-chair@example.test');
  insert into fx values ('chair', chair), ('paper', paper);
  -- a: delivered/delayed ordering, b: transient bounce, c: permanent bounce + complaint, d: queued same address, e: sending same address
  insert into fx select k, gen_random_uuid() from unnest(array['a','b','c','d','e','pa','pb','pc','pe']) k;
end $$;

insert into app_private.review_email_outbox (id, event_key, recipient_email, kind, payload, status, provider_id, paper_id, sent_at)
select (select v from fx where k=x.k), 'fb:'||x.k, x.email, 'decision', '{}'::jsonb, x.status,
       (select v::text from fx where k='p'||x.k), (select v from fx where k='paper'), case when x.status='sent' then now() end
from (values ('a','a@example.test','sent'),('b','b@example.test','sent'),('c','c@example.test','sent'),
             ('d','c@example.test','queued'),('e','c@example.test','sending')) x(k,email,status);

-- f: sent to the provider but the worker has not stored the provider ID yet
insert into fx select k, gen_random_uuid() from unnest(array['f','pf']) k;
insert into app_private.review_email_outbox (id, event_key, recipient_email, kind, payload, status, paper_id)
values ((select v from fx where k='f'), 'fb:f', 'f@example.test', 'decision', '{}'::jsonb, 'sending', (select v from fx where k='paper'));

create or replace function pg_temp.fb(msg text, typ text, k text, extra jsonb default '{}') returns text language sql as $$
  select public.record_email_feedback(repeat('t',40), msg,
    jsonb_build_object('type', typ, 'emailId', (select v::text from fx where k='p'||$3), 'notificationId', (select v::text from fx where k=$3)) || extra)
$$;

do $$
declare r text; st text; n int;
begin
  -- Authentication and validation
  begin perform public.record_email_feedback('wrong-token-wrong-token-wrong-token-xx', 'm0', '{"type":"email.delivered"}'); raise exception 'token accepted';
  exception when sqlstate '28000' then null; end;
  begin perform public.record_email_feedback(repeat('t',40), 'm0', '{"type":"email.opened","emailId":"00000000-0000-0000-0000-000000000000"}'); raise exception 'bad type accepted';
  exception when sqlstate '22023' then null; end;
  if public.record_email_feedback(repeat('t',40), 'm-unknown', jsonb_build_object('type','email.delivered','emailId',gen_random_uuid()::text)) <> 'ignored' then raise exception 'unknown provider id not ignored'; end if;
  if public.record_email_feedback(repeat('t',40), 'm-mismatch', jsonb_build_object('type','email.delivered','emailId',(select v::text from fx where k='pa'),'notificationId',gen_random_uuid()::text)) <> 'ignored' then raise exception 'tag mismatch not ignored'; end if;

  -- Early feedback: tag matches while provider ID is still empty; untagged early events cannot match
  if public.record_email_feedback(repeat('t',40), 'm-early-untagged', jsonb_build_object('type','email.delivered','emailId',(select v::text from fx where k='pf'))) <> 'ignored' then raise exception 'untagged early event matched'; end if;
  if pg_temp.fb('m-early','email.delivered','f') <> 'recorded' then raise exception 'early tagged event not recorded'; end if;
  if (select delivery_state from app_private.review_email_outbox where id=(select v from fx where k='f')) <> 'delivered' then raise exception 'early event state missing'; end if;
  -- Once the provider ID is stored, a different provider ID with the same tag is ignored
  update app_private.review_email_outbox set provider_id=(select v::text from fx where k='pf'), status='sent' where id=(select v from fx where k='f');
  if public.record_email_feedback(repeat('t',40), 'm-wrong-provider', jsonb_build_object('type','email.bounced','emailId',gen_random_uuid()::text,'notificationId',(select v::text from fx where k='f'))) <> 'ignored' then raise exception 'provider mismatch matched'; end if;

  -- Delivered, duplicate, weaker later event
  if pg_temp.fb('m1','email.delivered','a') <> 'recorded' then raise exception 'delivered not recorded'; end if;
  if pg_temp.fb('m1','email.delivered','a') <> 'duplicate' then raise exception 'duplicate not detected'; end if;
  perform pg_temp.fb('m2','email.delivery_delayed','a');
  select delivery_state into st from app_private.review_email_outbox where id=(select v from fx where k='a');
  if st <> 'delivered' then raise exception 'delayed overwrote delivered: %', st; end if;

  -- Transient bounce: recorded, not suppressed
  perform pg_temp.fb('m3','email.bounced','b','{"bounceType":"Transient","bounceSubType":"MailboxFull"}');
  select delivery_state into st from app_private.review_email_outbox where id=(select v from fx where k='b');
  if st <> 'bounced' or exists(select 1 from app_private.email_suppressions where email='b@example.test') then raise exception 'transient bounce handling wrong'; end if;

  -- Permanent bounce: suppression, queued row cancelled, sending row untouched
  perform pg_temp.fb('m4','email.bounced','c','{"bounceType":"Permanent","bounceSubType":"General"}');
  if not exists(select 1 from app_private.email_suppressions where email='c@example.test' and reason='bounce' and detail='General') then raise exception 'no suppression'; end if;
  select status into st from app_private.review_email_outbox where id=(select v from fx where k='d');
  if st <> 'cancelled' or (select last_error from app_private.review_email_outbox where id=(select v from fx where k='d')) <> 'recipient_suppressed' then raise exception 'queued row not cancelled'; end if;
  select status into st from app_private.review_email_outbox where id=(select v from fx where k='e');
  if st <> 'sending' then raise exception 'sending row changed'; end if;

  -- New mail to suppressed address is cancelled at insert; other addresses are not
  insert into app_private.review_email_outbox (event_key, recipient_email, kind, payload) values ('fb:new-c','c@example.test','decision','{}'), ('fb:new-a','a@example.test','decision','{}');
  if (select status||'/'||last_error from app_private.review_email_outbox where event_key='fb:new-c') <> 'cancelled/recipient_suppressed' then raise exception 'new suppressed insert not cancelled'; end if;
  if (select status from app_private.review_email_outbox where event_key='fb:new-a') <> 'queued' then raise exception 'unsuppressed insert changed'; end if;

  -- Complaint upgrades reason and state; a later bounce does not downgrade it
  perform pg_temp.fb('m5','email.complained','c');
  perform pg_temp.fb('m6','email.bounced','c','{"bounceType":"Permanent"}');
  if (select reason from app_private.email_suppressions where email='c@example.test') <> 'complaint' then raise exception 'complaint downgraded'; end if;
  if (select delivery_state from app_private.review_email_outbox where id=(select v from fx where k='c')) <> 'complained' then raise exception 'state downgraded'; end if;

  -- Resend suppression event suppresses
  perform pg_temp.fb('m7','email.suppressed','a');
  if not exists(select 1 from app_private.email_suppressions where email='a@example.test' and reason='bounce') then raise exception 'suppressed event ignored'; end if;
  select count(*) into n from app_private.email_feedback_events;
  if n <> 8 then raise exception 'expected 8 feedback events, got %', n; end if;
end $$;

-- anon may call the RPC (token-gated) but cannot read the private tables
set local role anon;
do $$
begin
  begin perform 1 from app_private.email_suppressions; raise exception 'anon read suppressions';
  exception when insufficient_privilege then null; end;
  begin perform public.record_email_feedback('nope', 'm9', '{}'); raise exception 'anon bypassed token';
  exception when sqlstate '28000' then null; end;
end $$;
reset role;

-- Chair status RPC returns delivery fields
select set_config('request.jwt.claims', json_build_object('sub', (select v from fx where k='chair'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
declare st text;
begin
  select delivery_state into st from public.review_email_status((select v from fx where k='paper')) where id=(select v from fx where k='c');
  if st is distinct from 'complained' then raise exception 'status RPC delivery_state: %', st; end if;
  begin perform 1 from app_private.email_feedback_events; raise exception 'authenticated read events';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- Purging an outbox row removes its feedback and suppression records
do $$
begin
  delete from app_private.review_email_outbox where id=(select v from fx where k='c');
  if exists(select 1 from app_private.email_suppressions where email='c@example.test') then raise exception 'suppression survived purge'; end if;
  if exists(select 1 from app_private.email_feedback_events where outbox_id=(select v from fx where k='c')) then raise exception 'events survived purge'; end if;
end $$;

select 'PASS: email delivery feedback' as result;
rollback;
