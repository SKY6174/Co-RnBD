-- Route replies by role: editorial mail to the program chair, everything else to the secretariat.
-- Only new rows are affected; queued rows keep their stored payload and idempotency body.
create or replace function app_private.set_review_email_reply_to()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.payload := new.payload || jsonb_build_object('replyTo',
    case when new.kind in ('reviewer_assignment','decision','review_submitted')
      then 'chair@co-rnbd.org' else 'office@co-rnbd.org' end);
  return new;
end;
$$;
revoke all on function app_private.set_review_email_reply_to() from public, anon, authenticated;
