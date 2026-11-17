-- Match delivery feedback that arrives before the worker has stored the Resend email ID.
-- Same signature, security and grants as 20261117090000_email_delivery_feedback.sql.

create or replace function public.record_email_feedback(p_token text, p_message_id text, p_event jsonb)
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

  -- Resend often reports delivery before the worker stores the provider ID (it collects the send
  -- acknowledgment on the next minute tick). The notification tag is our own outbox ID, so accept a
  -- tagged event while the provider ID is still empty; once stored, both must agree.
  select * into q from app_private.review_email_outbox o
  where case when notification_id is not null
    then o.id = notification_id::uuid and (o.provider_id is null or o.provider_id = email_id)
    else o.provider_id = email_id end
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
