-- Snapshot only new notifications so existing Resend idempotency payloads stay stable.
create function app_private.set_review_email_reply_to()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.payload := new.payload || jsonb_build_object('replyTo', 'office@co-rnbd.org');
  return new;
end;
$$;

revoke all on function app_private.set_review_email_reply_to() from public, anon, authenticated;

create trigger snapshot_review_email_reply_to
before insert on app_private.review_email_outbox
for each row execute function app_private.set_review_email_reply_to();
