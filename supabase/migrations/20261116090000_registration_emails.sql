-- Registration notices (operator request 2026-11-15): received, confirmed and cancelled mail to
-- the registrant's verified login email, through the existing private outbox and sender.
-- Off by default: nothing is queued or sent until review_email_config.registration_enabled is set.
alter table app_private.review_email_config add column registration_enabled boolean not null default false;
alter table app_private.review_email_outbox add column registration_id uuid references public.attendee_registrations(id) on delete set null;
create index review_email_registration_idx on app_private.review_email_outbox(registration_id);
alter table app_private.review_email_outbox drop constraint review_email_outbox_kind_check;
alter table app_private.review_email_outbox add constraint review_email_outbox_kind_check
  check(kind in ('reviewer_assignment','decision','review_submitted','paper_submitted','paper_resubmitted','author_submission_receipt','author_resubmission_receipt',
    'registration_received','registration_confirmed','registration_cancelled'));

-- Unchanged from 20261107160147 except the registration gate and send-time check.
create or replace function app_private.process_review_email_queue() returns void
language plpgsql security definer set search_path='' as $$
declare q record; cfg app_private.review_email_config; token text; provider text; expired boolean;
begin
  -- Never wait on another scheduler or an enqueue transaction.
  if not pg_try_advisory_xact_lock(6182741301) then return; end if;
  select * into cfg from app_private.review_email_config where id;
  -- Always collect acknowledgments, including while delivery is disabled.
  for q in select o.*,r.id as response_id,r.status_code,r.content,r.timed_out
    from app_private.review_email_outbox o left join net._http_response r on r.id=o.request_id
    where o.status='sending' and (r.id is not null or o.attempted_at<now()-interval '2 minutes')
    order by o.created_at limit 50 for update of o skip locked
  loop
    provider:=null;
    if q.status_code between 200 and 299 and not coalesce(q.timed_out,false) then
      begin provider:=q.content::jsonb->>'id'; exception when others then provider:=null; end;
    end if;
    if provider ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      update app_private.review_email_outbox set status='sent',provider_id=provider,sent_at=now(),last_error='' where id=q.id;
    elsif q.status_code between 400 and 499 and q.status_code not in (408,429) then
      update app_private.review_email_outbox set status='failed',last_error='http_'||q.status_code where id=q.id;
    else
      expired:=q.first_attempt_at<now()-interval '23 hours';
      update app_private.review_email_outbox set
        status=case when expired then 'uncertain' when q.attempts>=8 then 'failed' else 'retry' end,
        last_error=case when expired then 'idempotency_window' when q.response_id is null or coalesce(q.timed_out,false) then 'response_timeout'
          else 'http_'||coalesce(q.status_code::text,'unknown') end,
        next_attempt_at=now()+make_interval(secs=>least(3600,60*power(2,least(q.attempts,6))::integer))
      where id=q.id;
    end if;
  end loop;
  if not coalesce(cfg.enabled,false) then return; end if;
  select decrypted_secret into token from vault.decrypted_secrets where name='review_email_webhook_token' limit 1;
  if token is null or length(token)<32 then
    update app_private.review_email_config set last_error='hook_not_configured' where id; return;
  end if;
  update app_private.review_email_config set last_error='' where id and last_error<>'';
  for q in select * from app_private.review_email_outbox
    where status in ('queued','retry') and next_attempt_at<=now()
      and (kind<>'review_submitted' or cfg.review_submitted_enabled)
      and (kind not in ('paper_submitted','paper_resubmitted') or cfg.paper_submitted_enabled)
      and (kind not in ('author_submission_receipt','author_resubmission_receipt') or cfg.author_receipt_enabled)
      and (kind not in ('registration_received','registration_confirmed','registration_cancelled') or cfg.registration_enabled) order by created_at,id limit 2 for update skip locked
  loop
    if q.first_attempt_at is not null and q.first_attempt_at<now()-interval '23 hours' then
      update app_private.review_email_outbox set status='uncertain',last_error='idempotency_window' where id=q.id; continue;
    end if;
    if q.attempts>=8 then
      update app_private.review_email_outbox set status='failed',last_error='attempt_limit' where id=q.id; continue;
    end if;
    if not exists(select 1 from auth.users u where u.id=q.recipient_id and u.email_confirmed_at is not null and lower(u.email)=q.recipient_email) then
      update app_private.review_email_outbox set status='cancelled',last_error='recipient_changed' where id=q.id; continue;
    end if;
    if not q.is_test then
      if q.kind in ('registration_received','registration_confirmed','registration_cancelled') then
        -- Send only while the registration is still in the state the mail describes.
        if not exists(select 1 from public.attendee_registrations r
          where r.id=q.registration_id and r.user_id=q.recipient_id and r.status=q.payload->>'registrationStatus'
            and r.edition_year=app_private.current_edition_year()) then
          update app_private.review_email_outbox set status='cancelled',last_error='registration_obsolete' where id=q.id; continue;
        end if;
      end if;
      if q.kind in ('author_submission_receipt','author_resubmission_receipt') then
        -- A receipt confirms a committed historical submission, not the current editorial state.
        if not exists(select 1 from public.papers p join public.paper_events e on e.paper_id=p.id
          where p.id=q.paper_id and p.owner_id=q.recipient_id
            and e.id=(q.payload->>'submissionEventId')::uuid and e.action='paper_submitted'
            and e.after_data->>'status'='submitted'
            and (e.after_data->>'submitted_at')::timestamptz=(q.payload->>'manuscriptAt')::timestamptz
            and e.before_data->>'status'=case when q.kind='author_submission_receipt' then 'draft' else 'revision' end) then
          update app_private.review_email_outbox set status='cancelled',last_error='receipt_unavailable' where id=q.id; continue;
        end if;
      end if;
      if q.kind in ('paper_submitted','paper_resubmitted') then
        if not exists(select 1 from public.papers p where p.id=q.paper_id and p.status<>'draft'
          and p.edition_year=app_private.current_edition_year()
          and p.submitted_at=(q.payload->>'manuscriptAt')::timestamptz) then
          update app_private.review_email_outbox set status='cancelled',last_error='submission_obsolete' where id=q.id; continue;
        end if;
        if not exists(select 1 from app_private.review_submission_recipients(q.paper_id) t
          where t.user_id=q.recipient_id and t.email=q.recipient_email) then
          update app_private.review_email_outbox set status='cancelled',last_error='recipient_role_changed' where id=q.id; continue;
        end if;
      end if;
      if q.kind='review_submitted' then
        if not exists(select 1 from public.reviews r join public.papers p on p.id=r.paper_id
          where r.id=q.review_id and r.paper_id=q.paper_id and r.revoked_at is null and r.review_state='submitted'
            and r.manuscript_submitted_at=p.submitted_at and p.status<>'draft'
            and p.edition_year=app_private.current_edition_year()
            and md5(jsonb_build_array(r.recommendation,r.comments)::text)=q.payload->>'reviewFingerprint') then
          update app_private.review_email_outbox set status='cancelled',last_error='review_obsolete' where id=q.id; continue;
        end if;
        if not exists(select 1 from app_private.review_submission_recipients(q.paper_id) t
          where t.user_id=q.recipient_id and t.email=q.recipient_email) then
          update app_private.review_email_outbox set status='cancelled',last_error='recipient_role_changed' where id=q.id; continue;
        end if;
      end if;
      if q.kind='reviewer_assignment' and not exists(
        select 1 from public.reviews r join public.papers p on p.id=r.paper_id
        where r.id=q.review_id and r.revoked_at is null and r.review_state<>'declined'
          and r.manuscript_submitted_at=p.submitted_at and p.status in ('submitted','under_review')) then
        update app_private.review_email_outbox set status='cancelled',last_error='assignment_obsolete' where id=q.id; continue;
      end if;
      if q.kind='decision' and not exists(
        select 1 from public.papers p where p.id=q.paper_id and p.status=q.payload->>'decision'
          and p.decision_published_at=(q.payload->>'publishedAt')::timestamptz
          and p.submitted_at=(q.payload->>'manuscriptAt')::timestamptz) then
        update app_private.review_email_outbox set status='cancelled',last_error='decision_obsolete' where id=q.id; continue;
      end if;
    end if;
    begin
      update app_private.review_email_outbox set status='sending',attempts=attempts+1,
        first_attempt_at=coalesce(first_attempt_at,now()),attempted_at=now(),last_error='',
        request_id=net.http_post(url:=cfg.endpoint,headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||token),
          body:=q.payload||jsonb_build_object('eventId',q.id,'test',q.is_test),timeout_milliseconds:=12000)
      where id=q.id;
    exception when others then
      -- A transient network extension/config issue must not roll back a paper decision.
      update app_private.review_email_outbox set status='retry',last_error='dispatch_unavailable',
        attempts=attempts+1,first_attempt_at=coalesce(first_attempt_at,now()),next_attempt_at=now()+interval '5 minutes' where id=q.id;
    end;
  end loop;
end; $$;

revoke all on function app_private.process_review_email_queue() from public,anon,authenticated;

create function app_private.enqueue_registration_email() returns trigger
language plpgsql security definer set search_path='' as $$
declare address text; recipient_name text; mail_kind text; valid_address boolean;
begin
  if not exists(select 1 from app_private.review_email_config where id and registration_enabled) then return new; end if;
  if tg_op='INSERT' then
    if new.status<>'applied' then return new; end if;
    mail_kind:='registration_received';
  elsif new.status is not distinct from old.status then return new;
  else
    mail_kind:=case new.status when 'applied' then 'registration_received' when 'confirmed' then 'registration_confirmed' else 'registration_cancelled' end;
  end if;
  select lower(u.email),coalesce(nullif(btrim(pr.full_name),''),'참가자') into address,recipient_name
    from auth.users u left join public.profiles pr on pr.user_id=u.id
    where u.id=new.user_id and u.email_confirmed_at is not null;
  valid_address:=coalesce(address ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' and char_length(address)<=254,false);
  insert into app_private.review_email_outbox(event_key,registration_id,recipient_id,recipient_email,kind,payload,status,last_error)
    values('registration:'||new.id::text||':'||new.status||':'||to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US'),
      new.id,new.user_id,coalesce(address,''),mail_kind,
      jsonb_build_object('version',5,'kind',mail_kind,'recipient',coalesce(address,''),'recipientName',left(coalesce(recipient_name,'참가자'),120),
        'registrationId',new.id,'registrationStatus',new.status,'category',new.category,'attendanceDays',to_jsonb(new.attendance_days),
        'editionYear',new.edition_year,'conferenceTitle',(select title from public.conference_editions where year=new.edition_year),'note',''),
      case when valid_address then 'queued' else 'failed' end,case when valid_address then '' else 'recipient_unverified' end)
    on conflict(event_key) do nothing;
  -- Enqueue only: the existing dispatcher/cron sends it.
  return new;
end; $$;
revoke all on function app_private.enqueue_registration_email() from public,anon,authenticated;
create trigger enqueue_registration_email after insert or update of status on public.attendee_registrations
  for each row execute function app_private.enqueue_registration_email();
