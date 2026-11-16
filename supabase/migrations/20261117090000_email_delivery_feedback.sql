-- Record Resend delivery feedback for outbox mail and stop mailing addresses that hard-bounce or complain.
-- Inactive until a Resend webhook is registered: nothing here sends mail or changes the dispatch worker.

alter table app_private.review_email_outbox
  add column delivery_state text check (delivery_state in ('delivered','delayed','bounced','complained')),
  add column delivery_at timestamptz;

create index review_email_provider_idx on app_private.review_email_outbox(provider_id) where provider_id is not null;
create index review_email_recipient_email_idx on app_private.review_email_outbox(recipient_email);

-- One row per accepted webhook delivery, so provider retries are applied once.
create table app_private.email_feedback_events (
  svix_id text primary key check (char_length(svix_id) between 1 and 100),
  outbox_id uuid not null references app_private.review_email_outbox(id) on delete cascade,
  type text not null,
  received_at timestamptz not null default now()
);
create index email_feedback_events_outbox_idx on app_private.email_feedback_events(outbox_id);

-- Addresses that must not receive further notifications. Tied to the outbox row that caused them,
-- so the existing post-event purge of the outbox also removes these records.
create table app_private.email_suppressions (
  email text primary key check (email = lower(email) and char_length(email) between 3 and 254),
  reason text not null check (reason in ('bounce','complaint')),
  detail text not null default '' check (char_length(detail) <= 60),
  source_outbox_id uuid not null references app_private.review_email_outbox(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index email_suppressions_source_idx on app_private.email_suppressions(source_outbox_id);

alter table app_private.email_feedback_events enable row level security;
alter table app_private.email_suppressions enable row level security;
revoke all on app_private.email_feedback_events, app_private.email_suppressions from public, anon, authenticated;

-- New notifications to a suppressed address are cancelled before the worker can pick them up.
create function app_private.cancel_suppressed_review_email()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status in ('queued','retry')
    and exists (select 1 from app_private.email_suppressions s where s.email = lower(new.recipient_email)) then
    new.status := 'cancelled';
    new.last_error := 'recipient_suppressed';
  end if;
  return new;
end;
$$;
revoke all on function app_private.cancel_suppressed_review_email() from public, anon, authenticated;

create trigger cancel_suppressed_review_email
before insert on app_private.review_email_outbox
for each row execute function app_private.cancel_suppressed_review_email();

-- Called by the production Vercel webhook route after it has verified the Resend (Svix) signature.
-- The shared token is the existing review_email_webhook_token in Vault.
create function public.record_email_feedback(p_token text, p_message_id text, p_event jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  expected text;
  kind text := p_event->>'type';
  email_id text := p_event->>'emailId';
  notification_id text := p_event->>'notificationId';
  bounce_type text := coalesce(p_event->>'bounceType', '');
  bounce_sub text := coalesce(p_event->>'bounceSubType', '');
  occurred timestamptz;
  q app_private.review_email_outbox;
  new_state text;
  suppress text;
  uuid_re constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
begin
  select decrypted_secret into expected from vault.decrypted_secrets where name = 'review_email_webhook_token' limit 1;
  if expected is null or length(expected) < 32 or p_token is null
    or extensions.digest(p_token, 'sha256') <> extensions.digest(expected, 'sha256') then
    raise exception 'Unauthorized' using errcode = '28000';
  end if;

  if p_message_id is null or char_length(p_message_id) not between 1 and 100
    or kind not in ('email.delivered','email.delivery_delayed','email.bounced','email.complained','email.suppressed')
    or email_id is null or email_id !~ uuid_re
    or (notification_id is not null and notification_id !~ uuid_re)
    or char_length(bounce_type) > 60 or char_length(bounce_sub) > 60 then
    raise exception 'Invalid feedback event' using errcode = '22023';
  end if;
  begin
    occurred := coalesce((p_event->>'occurredAt')::timestamptz, now());
  exception when others then
    raise exception 'Invalid feedback event' using errcode = '22023';
  end;

  select * into q from app_private.review_email_outbox o
  where o.provider_id = email_id and (notification_id is null or o.id = notification_id::uuid)
  for update;
  if not found then return 'ignored'; end if;

  insert into app_private.email_feedback_events(svix_id, outbox_id, type)
  values (p_message_id, q.id, kind) on conflict (svix_id) do nothing;
  if not found then return 'duplicate'; end if;

  -- complained > bounced > delivered > delayed; a later weaker event never hides a stronger one.
  new_state := case kind
    when 'email.complained' then 'complained'
    when 'email.delivered' then 'delivered'
    when 'email.delivery_delayed' then 'delayed'
    else 'bounced' end;
  if q.delivery_state is null
    or array_position(array['delayed','delivered','bounced','complained'], new_state)
       >= array_position(array['delayed','delivered','bounced','complained'], q.delivery_state) then
    update app_private.review_email_outbox set delivery_state = new_state, delivery_at = occurred where id = q.id;
  end if;

  suppress := case
    when kind = 'email.complained' then 'complaint'
    when kind = 'email.suppressed' then 'bounce'
    when kind = 'email.bounced' and bounce_type = 'Permanent' then 'bounce'
    else null end;
  if suppress is not null then
    insert into app_private.email_suppressions(email, reason, detail, source_outbox_id)
    values (lower(q.recipient_email), suppress, left(coalesce(nullif(bounce_sub, ''), bounce_type), 60), q.id)
    on conflict (email) do update set
      reason = case when app_private.email_suppressions.reason = 'complaint' then 'complaint' else excluded.reason end,
      detail = excluded.detail, updated_at = now();
    update app_private.review_email_outbox set status = 'cancelled', last_error = 'recipient_suppressed'
    where lower(recipient_email) = lower(q.recipient_email) and status in ('queued','retry');
  end if;
  return 'recorded';
end;
$$;
revoke all on function public.record_email_feedback(text, text, jsonb) from public;
grant execute on function public.record_email_feedback(text, text, jsonb) to anon, authenticated;

-- Status for chair/AE now includes the provider delivery result.
drop function public.review_email_status(uuid);
drop function app_private.review_email_status(uuid);
create function app_private.review_email_status(p_id uuid) returns table(
  id uuid,kind text,status text,recipient_email text,attempts integer,created_at timestamptz,sent_at timestamptz,last_error text,enabled boolean,
  delivery_state text,delivery_at timestamptz)
language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is null or not(app_private.is_chair() or app_private.is_paper_editor(p_id)) then
    raise exception 'Editorial permission required';
  end if;
  return query select q.id,q.kind,q.status,q.recipient_email,q.attempts,q.created_at,q.sent_at,
    coalesce(nullif(q.last_error,''),nullif(c.last_error,''),''),c.enabled and (q.kind<>'review_submitted' or c.review_submitted_enabled)
      and (q.kind not in ('paper_submitted','paper_resubmitted') or c.paper_submitted_enabled)
      and (q.kind not in ('author_submission_receipt','author_resubmission_receipt') or c.author_receipt_enabled),
    q.delivery_state,q.delivery_at
    from app_private.review_email_outbox q cross join app_private.review_email_config c
    where q.paper_id=p_id order by q.created_at desc,q.id limit 100;
end; $$;
revoke all on function app_private.review_email_status(uuid) from public,anon;
grant execute on function app_private.review_email_status(uuid) to authenticated;
create function public.review_email_status(p_id uuid) returns table(
  id uuid,kind text,status text,recipient_email text,attempts integer,created_at timestamptz,sent_at timestamptz,last_error text,enabled boolean,
  delivery_state text,delivery_at timestamptz)
language sql security invoker set search_path='' as $$ select * from app_private.review_email_status(p_id); $$;
revoke all on function public.review_email_status(uuid) from public,anon;
grant execute on function public.review_email_status(uuid) to authenticated;
